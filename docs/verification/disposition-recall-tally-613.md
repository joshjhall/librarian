# Disposition-policy recall tally — issue #613

Completed measurement for
[#613](https://github.com/joshjhall/librarian/issues/613)
("verify the new disposition policy's recall"). Follow-up to
[#580](https://github.com/joshjhall/librarian/issues/580), which replaced an
unsatisfiable prose policy with the `dispositionOf` rule list.

**Status: CLOSED — all three acceptance criteria answered, on one unrelated
batch; this does not establish a general blocking rate.** The row target
(~10 cycles) is met at 11, and rows 6–10 supplied
the ingredient rows 0–5 could not: cycles from an **unrelated** issue, and the
first `R8` fires. See § Verdict for the finding.

No further rows are being collected. The one thing the data does not establish is
**breadth** — a single unrelated batch cannot turn the observed blocking rate into
a general rate — and that is recorded in § Verdict as a limitation of the finding
rather than as outstanding work. The reason this is a defensible stop rather than
an abandonment: the instrument is permanent, so a second batch costs nothing to
collect if a suspicion ever arises, and there is currently no suspicion to test.

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

This is how the rows below **were** collected; it is a record of method, not a
live instruction. The append step it describes was retired from
`ci-review-protocol.md` step (d) when the measurement closed — that step now
keeps only the deferrable-bucket read, which was never specific to this tally.

One row per **review cycle** (not per issue — a re-review cycle got its own
row), same shape as the #567 batch it follows.

Every cycle's harness result reported both distributions directly, so no row was
hand-derived:

```bash
jq '{cycle, by_nature: .summary.by_nature, by_rule: .summary.by_rule,
     total: .summary.total_findings, blocking: .summary.by_disposition.blocking}' \
  "$cycle_result_json"
```

That command still works — the harness continues to emit both distributions on
every cycle — so a future batch can be collected the same way without
re-deriving anything.

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

**Cycles tallied: 11 — final.** Rows 0–5 are the review cycles of the PR that
introduced the instrument — not a neutral sample (see § Reading these six rows
together). Rows 6–10 are the **first batch from an unrelated issue** (#673),
which is precisely what those notes said was needed before the `nature`
distribution means anything.

| # | issue | tier | files | +/- | cycle | total | blocking | `by_nature` | `by_rule` | deferred defect? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 613 | small code+test+docs | 4 | +366/-10 | 1 | 3 | 0 | improvement 3 | R2 1, R4 2 | **no** — 3 real improvements, all fixed anyway |
| 1 | 613 | (re-review) | 4 delta | +242 delta | 2 | 1 | 0 | improvement 1 | R4 1 | **no** — a real, self-documented coverage gap |
| 2 | 613 | (re-review, narrow) | 1 delta | +61 delta | 3 | 0 | 0 | (none) | (none) | n/a — zero findings, `C3` uninformative |
| 3 | 613 | (re-review, FULL) | 5 | +647 full | 4 | 1 | 0 | improvement 1 | R4 1 | **no** — but see below |
| 4 | 613 | (re-review, narrow) | 2 delta | +149 delta | 5 | 0 | 0 | (none) | (none) | n/a — zero at 23% surface, `C1-cap` |
| 5 | 613 | (confirmation, FULL) | 5 | +647 full | 6 | 0 | 0 | (none) | (none) | **no** — zero on a comparable surface |
| 6 | 673 | medium code+test+docs | 8 | +869 full | 1 | 10 | **2** | defect-in-new-code 1, incomplete-work 1, improvement 8 | R2 2, R4 6, R6 1, R8 1 | **yes** — 2 deferrables were the same class as the confirmed blockers (see Row 6 notes) |
| 7 | 673 | (re-review, delta) | 4 delta | +278 delta | 2 | 4 | **2** | defect-in-new-code 2, improvement 2 | R2 1, R4 1, R8 2 | **no** — both defects blocked correctly |
| 8 | 673 | (re-review, FULL) | 8 | +1259 full | 3 | 3 | **1** | defect-in-new-code 1, improvement 2 | R4 2, R8 1 | **no** |
| 9 | 673 | (re-review, FULL) | 8 | +1259 full | 4 | 2 | **1** | incomplete-work 1, improvement 1 | R2 1, R6 1 | **no** |
| 10 | 673 | (re-review, FULL) | 8 | +1259 full | 5 | 4 | **1** | defect-in-new-code 1, improvement 3 | R4 3, R8 1 | **no** — but the cycle ended on `C1-cap` over `C8-novel` (see Row 10 notes) |

### Rows 6-10 notes — the first non-self-referential batch, and the first `R8` fires

**`R8` fired for the first time — five times across four cycles — and every fire
was a real defect.** Rows 0–5 could not test the rule that exists to catch the
defects #580 missed, because no cycle produced a `defect-in-new-code`. Summing the
`by_rule` column for rows 6–10 gives `R8` = 1 + 2 + 1 + 0 + 1 = **5**. Four are
described below, each confirmed by reproduction before it was accepted; the fifth
is row 7's second `R8` finding, which was blocked and fixed in the same cycle as
C2 and was not written up separately:

1. **C1** — a per-lane `dispatched` check tested `= "true"` while its sibling
   header tested `= "false"`. Since `jq` prints `"null"` for an absent key, a
   pre-existing plan file rendered already-running lanes as freshly launchable
   *while the header one line above said "already in flight"*. Reproduced.
2. **C2** — the fix for (1) added a documented recipe staging through a fixed
   `/tmp/tracks.json`: symlink race plus a non-atomic cross-filesystem `mv`. The
   codebase had hardened two sibling sites against exactly this.
3. **C3** — the launch command was built inline in an `echo`, so a failed
   subprocess rendered a blank line at exit 0. Reproduced with a failing stub.
4. **C5** — a corrupt plan file rendered as an *empty* one: 0 lanes, "already in
   flight", exit 0. Reproduced with a truncated file.

**The blocking rate here is 7 blocking / 23 findings (30%)**, against 0/5 in rows
0–5. That is the first data point suggesting the policy blocks when there is
something to block on, rather than being uniformly permissive — the open question
rows 0–5 explicitly could not answer.

**Two cautions this batch confirms rather than merely repeats.**

*A fix commit invalidates the prior cycle's read* — stated in § Verdict from
the #567 batch, and demonstrated here twice: C2's blocking finding was in code C1's
fix introduced, and C5's was in a file three fixes had already touched. Two of
five defects were **created by the review loop itself**. The per-cycle row is not
bookkeeping; it is the only way this is visible.

*Row 6's deferred-defect check is a `yes`, and it is the informative one.* Two
findings the judge put in the deferrable bucket — a documented "mark the lane
dispatched" step with **no writer**, and three untested status-label arms
including the padding boundary the code's own comment warns about — were the same
class as the `--recompose` finding it had just called `incomplete-work` and
blocked. Both were promoted and fixed on merit. The judge's `improvement` calls
were defensible one at a time; the *pattern* across the bucket was not. This is
the first row in the whole tally where reading deferrables on merit changed the
outcome, which is precisely the standing rule's purpose.

### Row 10 notes — `C1-cap` masked `C8-novel`, exactly as row 4 predicted

Cycle 5 returned `verdict=stop`, `rule=C1-cap`, **`capped_over=C8-novel`**, with
`novel=4`. Re-running the predicate uncapped (`--max-cycles 9`) returns
**`continue` / `C8-novel` / `novel-material`**: the loop did not converge, it ran
out of budget.

Rows 4–5 flagged this masking as "worth carrying forward beyond this issue" and
recommended the uncapped re-run as the cheap disambiguation. This is its first
use on an unrelated issue, and it changed the disposition: the run was treated as
a **dead-end** — PR parked for human review rather than merged — instead of
reading `stop` as done. Every one of the five cycles found a blocking defect and
the severity never reached zero, so "converged" was never a defensible reading.

`capped_over` is now doing real work. It exists so a caller can tell a genuine
stop from a budget artifact without re-deriving anything, and here it is the
single field that separated "ready to merge" from "not reviewed to exhaustion".

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

### Rows 4-5 notes — and a finding about the stop rule itself

Row 4 (cycle 5) returned zero, and `review-convergence.sh` said `stop` — but via
**`C1-cap`**, the hard ceiling, on a delta of 149 lines against the previous
cycle's 647. That is **23% of the prior surface**, well under the 50%
comparability floor. Had the cap not fired first, that same zero would have
tripped `C3-narrow-zero` and the loop would have continued.

So the protocol's own stop signal was, at that moment, indistinguishable from
"we ran out of budget on an uninformative cycle". Merging there would have been
defensible by the letter of the rule and wrong in substance — and cycle 4 on this
very PR had just demonstrated that a full re-read finds what narrow cycles miss.

Row 5 is the extra confirmation cycle run for that reason: the **full** 647-line
diff again, a comparable surface. Zero findings. Re-running the predicate
uncapped returns **`C4-zero` / `zero-comparable-surface`** — it stops on
convergence grounds *independent of the cap*. That is the signal worth merging
on.

**Worth carrying forward beyond this issue.** `C1-cap` masking a would-be `C3`
is a real gap in the stop rule: a cap-terminated cycle whose zero came over a
sub-ratio surface reports `stop` with no indication that convergence was never
actually established. A caller reading only `verdict` cannot tell the two apart.
Re-running the predicate with a raised `--max-cycles` is the cheap disambiguation
(it is a pure function of the inputs), and doing so is what distinguished a real
stop from a budget artifact here. This is the first observation in the batch that
is about the *review protocol* rather than the disposition policy, and it did not
require the instrument to find — but it did require refusing to read `stop` as
"done".

### Reading these six rows together

All six cycles: `blocking: []`, `clean: true`, deferred-defect check `no`.
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

**The 0% blocking rate here is not reassuring or alarming — it is
uninformative,** and saying so is the point. `R8` (the rule that exists to catch
the six defects #580 missed) has never fired, because no cycle produced a
`defect-in-new-code` for it to fire on. Whether `R8` works in production is
precisely the open question, and this batch could not test it.

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

> **Superseded by rows 6–10.** The paragraphs above are the reading of rows 0–5
> and are left as written — they were accurate for that batch and the reasoning
> is what makes rows 6–10 legible. But "`R8` has never fired" and "six of eight
> rules have never fired" are **no longer current**: rows 6–10 fired `R8` five
> times (every one a real defect) plus `R6`, and supplied the unrelated-issue
> sample this caveat asks for. See § Rows 6-10 notes and § Verdict.

## Verdict

**No evidence of a systematic `nature` miscall; the policy is behaving as
designed.** Rows 6–10 answer the first AC and turn the second from unanswerable
into answered. The scope of that answer — one unrelated issue, not a general rate
— is stated as a limitation below rather than left implicit.

- **Is the blocking rate plausible? — Yes, on the evidence so far.** 0/5 blocking
  across rows 0–5 and **7/23 (30%)** across rows 6–10. Neither extreme #613 warned
  about appeared: not the ~1.5% that was the #580 bug, not the ~100% that would
  dead-end every cycle at the cap. The policy blocked when there was something to
  block on and deferred when there was not, and the difference between the two
  batches tracks the diffs, not the policy.
- **Did any cycle defer a confirmed new-code defect? — Yes, once (row 6),** and
  the mechanism is more interesting than the count. No single deferral was
  clearly miscalled; the *pattern* was. Two `improvement` findings sat in the
  deferrable bucket while a third finding of the same class — prose asserting a
  mechanism nothing implements — was correctly blocked as `incomplete-work` in
  the same cycle. Reading the bucket on merit caught it; no aggregate would have.
- **Is `nature` systematically miscalled? — No evidence of it.** `R8` fired five
  times and every fire was a real, reproduced defect: no false positives. The one
  boundary worth watching is `improvement` vs `incomplete-work` for
  documentation-asserts-nonexistent-behavior, which row 6 shows landing on both
  sides within a single cycle.

**Limitation of this finding — breadth.** One unrelated issue is one sample, and
both batches were reviewed by the same author-plus-harness pairing. So the 30%
should be read as *this policy blocked proportionately on the diffs it was shown*,
not as a rate that generalizes; a second unrelated batch is what would distinguish
the two. Anyone citing this measurement should cite it at that width.

**No follow-up is filed** — neither on `judgePrompt` (per AC 3) nor on the breadth
gap, and for the same reason in both cases: the data does not show a defect to
fix, and filing an issue now would be guessing at a finding the measurement did
not make. The breadth gap in particular needs no ticket to stay actionable,
because the instrument is **permanent** — every review cycle computes `by_nature`
and `by_rule` whether or not anyone is tallying them. If a future cycle ever
raises a real suspicion about how `nature` is being assigned, a second batch is
already there to be collected. That is a better trigger than a standing reminder
to re-measure something that currently looks correct.

Two cautions carried forward from the #567 notes, both of which cost that batch
time — and **both of which fired again in rows 6–10**, the second one twice:

- **Zero-finding trivial cycles are not evidence.** A comment-only diff *should*
  find nothing. Recall gets tested on medium-tier diffs and on re-review cycles
  over fix commits.
- **A fix commit invalidates the prior cycle's clean read.** In the #567 batch a
  cycle-1 `blocking: []` was followed by a real defect *introduced by the cycle-1
  fix*. Each cycle is its own row for this reason.

## What AC 3 asked for, and what happened

AC 3 made the follow-up **conditional**: if `nature` turned out to be
systematically miscalled, the fix would be either the judge prompt (`judgePrompt`
in `plugins/workflow/skills/ship-issue/workflow.js`, where the four definitions
live) or validating `nature` against the changed-file list — the judge already
receives that list, so that check was available without new plumbing.

The condition was not met, so **neither was filed.** `R8` fired five times with no
false positives, and the one boundary the data does show as genuinely contested —
`improvement` vs `incomplete-work` for documentation asserting a mechanism nothing
implements, which row 6 shows landing on both sides within a single cycle — is a
judgment call at the edge of two reasonable definitions, not a miscall a prompt
edit would fix. Both remedies remain available and are recorded here so a future
reader does not have to re-derive them.

## The standing rule this measurement corroborated

The rule #580 documented — **`blocking: []` is not a merge signal** — was the
backstop while recall was unverified. It does **not** retire now that the
measurement is closed: it is permanent, and this batch is the strongest evidence
for it rather than a reason to relax it.

Row 6 is the case in point. Two findings the judge placed in the deferrable bucket
were the same class as a third it had just blocked; no aggregate would have shown
that, and no single deferral was clearly miscalled on its own. Reading the bucket
on merit is what caught it. That read is stated at `ci-review-protocol.md` step
(d) and remains mandatory on every cycle — a well-calibrated policy is exactly the
condition under which a miscall is hardest to notice.
