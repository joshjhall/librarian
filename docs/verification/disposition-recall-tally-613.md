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

**Cycles tallied: 0 of ~10.** No rows yet — the instrument landed with this file,
so the first rows come from the review cycles of the PR that introduced it and
any subsequent shipped issue.

| # | issue | tier | files | +/- | cycle | total | blocking | `by_nature` | `by_rule` | deferred defect? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| *(none yet)* | | | | | | | | | | |

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
