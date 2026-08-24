# Investigation-delegation cost & recall tally — issue #785

**Status: OPEN — the instrument, with no rows yet.** This file ships with the
guidance change ([#785](https://github.com/joshjhall/librarian/issues/785)) and is
filled by [#797](https://github.com/joshjhall/librarian/issues/797), the
measurement follow-up that owns AC5/AC6. Rows are appended as windows
are captured, so this is a running tally rather than a completed report (per
CLAUDE.md § `docs/verification/`).

**Figures here are NORMALIZED — percentages and ratios only.** See
[`token-baseline-tally-781.md`](token-baseline-tally-781.md) § Why no absolute
figures: this repo is public and committing fleet-wide request counts or dollar
totals would publish this org's LLM spend permanently.

## Why this could not be measured in the shipping PR

Issue #785's AC5 and AC6 ask for a **post-deployment** observation:

- **AC5** — "subagents return conclusions, not transcripts — verified on a real
  run that the parent context did not absorb the exploration"
- **AC6** — "before/after per-model split measured via #781, showing opus token
  share falling"

Both need the guidance to be *in agents' hands and running* before there is an
"after" to measure. The PR that adds the guidance cannot contain its own effect,
and `BIFROST_URL` is unset in the authoring environment besides. Rather than
close those ACs unmeasured,
[#797](https://github.com/joshjhall/librarian/issues/797) owns them and points
here. That issue — not this file, and not #785 — is what stops this becoming
"shipped and forgotten": it stays open until the row target below is met and this
tally is closed with a verdict.

### Why `Closes #785` and not `Contributes to #785`

A reasonable reading says a PR leaving two ACs unmet should say `Contributes`
(this repo's umbrella-issue convention). The **operator's explicit decision** was
the other split, and it is recorded here so it is not re-litigated by whoever
reads this next:

**Issue #785 is the guidance change and closes on it (AC1–AC4). Issue #797 is a
separate issue that OWNS AC5/AC6 outright** — it does not merely track a
remainder of #785. The two ACs were moved, not deferred-in-place.

That distinction is what makes `Closes` correct rather than sloppy: the
alternative would leave #785 open indefinitely as a stale umbrella whose only
live content had already moved elsewhere, which is exactly the ambiguity
splitting the issue was meant to remove. The evidence stays separate from the
change it judges — a measurement issue outliving the change it measures is
normal.

The thing this must not become is a closed issue with no live owner for the
unmeasured claim. #797 is that owner, is open, and is linked from every mention
above.

Shipping the recipe now — while the context that produced it is live — is
deliberate. Re-deriving the method later is exactly the transcript archaeology
[#781](https://github.com/joshjhall/librarian/issues/781) was filed to end.

## What is being measured

The change routes read-only investigation from the opus main session to sonnet
subagents when it clears a break-even. Two things can go wrong, and only one of
them is visible in a token report:

1. **The saving does not materialize** — the guidance is not followed, or it is
   followed on work below the break-even and costs *more*. Visible in AC6's
   per-model split.
2. **Recall degrades** — delegated investigations miss things the inline reading
   would have caught. **Not** visible in any token metric, and this is the
   dangerous one.

### The recall problem, stated honestly up front

The prior art is `.claude/memory/review-cost-after-2026-07-28.md`, the AFTER arm
for the #553/#557 exploration bounds. Its verdict is the model for this one:

> Do not record this as "recall held." Record it as "recall did not visibly
> break, on two cycles, one of which found nothing."

The failure mode transfers exactly. **A delegated investigation that misses
something looks identical to one that found nothing to report.** Zero findings is
equally consistent with "clean" and with "the subagent stopped looking". #785's
own body anticipates this and says to plan for more than two samples.

**Row target: >= 10 delegated investigations across >= 3 distinct issues**, before
any success verdict. Fewer than that cannot separate the two readings above, and
a single batch cannot turn an observed rate into a general one.

## Method

### AC6 — the per-model split

Both windows are regenerated at compare time (no baseline `.tsv` is committed —
`compare` diffs absolute fields, so a normalized one would yield meaningless
deltas and a faithful one would commit the figures § above withholds):

```bash
export BIFROST_URL=https://bifrost.example        # gateway ADMIN root, NOT ANTHROPIC_BASE_URL
TR=plugins/workflow/scripts/token-report.sh

# BEFORE — the #781 reference window
"$TR" window --start 2026-08-22T18:00:00Z --end 2026-08-23T18:00:00Z > /tmp/baseline.tsv

# AFTER — a comparable window once the guidance has been running
"$TR" window --start <after-start> --end <after-end> > /tmp/after.tsv

# Percentages ONLY — the default output carries raw spend and must not be pasted
"$TR" compare --baseline /tmp/baseline.tsv --compare /tmp/after.tsv --percent-only
```

The `/tmp` intermediates carry full absolutes and are never committed.

**The headline is `avg_prompt_per_request`, not cost** — cost moves with how hard
the fleet is pushed, while the average isolates an efficiency change from a
workload change. Baseline: **151,739** fleet-wide; opus-5 at **41.9% of requests
/ 80.7% of cost**. The success signal for #785 is **opus's share of tokens
falling** while the fleet average does not rise.

**Reconciliation is not optional.** `token-report.sh` fails loud (exit 1) when
per-model counts do not sum to the unfiltered total, because a dropped filter
param returns the unfiltered total with HTTP 200 — a wrong number that reads as
right. Record the reconciliation delta with every row.

### AC5 — conclusions, not transcripts

Per-run, from the session transcript:

```sh
# Result volume the PARENT absorbed from a delegated investigation.
# Dedup by message.id or figures run ~2x high — see the memory note.
jq -rn --slurpfile r "$f" '[$r[]|select(.message.usage!=null)
  |{id:.message.id,u:.message.usage}]|unique_by(.id)
  |{turns:length, cr:([.[].u.cache_read_input_tokens//0]|add)}'
```

The check is that the subagent's **return value** carries an answer plus
`file:line` anchors, and that the parent's context growth across the delegation
is bounded by that conclusion — not by the volume the subagent read. A delegation
whose conclusion is a file dump has bought only a spawn prefix and must be
recorded as a **failure of the guidance**, not of the measurement.

### Recall — the part with no clean instrument

For each delegated investigation, record what the conclusion **claimed** and
whether any later step in the same issue (review harness finding, CI failure,
human correction) surfaced something the investigation should have found. This is
weak evidence per row and only becomes a signal in aggregate, which is why the
row target is what it is.

## Rows

| # | date | issue | investigation | delegated? | parent ctx growth | missed later? | notes |
| ---: | --- | --- | --- | --- | ---: | --- | --- |
| | | | | | | | *(none yet — see § Status)* |

## Per-model windows

| window | opus req share | opus cost share | fleet avg prompt/req | reconcile delta | notes |
| --- | ---: | ---: | ---: | ---: | --- |
| 2026-08-22T18:00Z .. 2026-08-23T18:00Z | 41.9% | 80.7% | 151,739 | 0 | #781 baseline (before) |

## Verdict

*Not yet reached — no rows.* To be written under
[#797](https://github.com/joshjhall/librarian/issues/797) when the row target is
met, in the form the prior art demands: state what the data **does** establish
and what it does not, and do not upgrade "did not visibly break" into "held".
