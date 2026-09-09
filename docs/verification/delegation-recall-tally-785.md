# Investigation-delegation cost & recall tally — issue #785

**Status: CLOSED — see § Verdict.** This file shipped with the guidance change
([#785](https://github.com/joshjhall/librarian/issues/785)) as the instrument for
its AC5/AC6, and was filled and closed by
[#797](https://github.com/joshjhall/librarian/issues/797), the measurement
follow-up that owns those two criteria.

**It closes on a result nobody planned for: the guidance never fired.** The row
target below (>= 10 delegated investigations) is not merely unmet — it is
unreachable from the measured corpus, which contains **zero** delegated
investigations against 49 inline ones that cleared the break-even. So the recall
question this tally was built to answer is **UNTESTED**, a third state distinct
from both readings its § *The recall problem* anticipated, and the live finding
is non-adoption, tracked as
[#978](https://github.com/joshjhall/librarian/issues/978). See § Verdict.

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

Measured 2026-09-09 with `plugins/workflow/scripts/delegation-adoption.sh`
(shipped by #797 — the count is re-derivable, not hand-tallied). Corpus: every
local transcript under `~/.claude/projects`, 2026-09-07 .. 09-09 — i.e. a window
opening **two weeks after** the guidance merged (`ff01b88`, 2026-08-24).

| # | date | corpus | delegated investigations | parent ctx growth | missed later? | notes |
| ---: | --- | --- | ---: | --- | --- | --- |
| 1 | 2026-09-09 | 118 subagent spawns, 13 sessions | **0** | n/a | n/a | 117 of 118 spawns are `ship-issue` review-harness fan-out (`subagents/workflows/**`), which happen with or without the guidance |
| 2 | 2026-09-09 | the 1 non-harness spawn | 1 (`claude-code-guide`) | ~417 tok returned | not observed | a **docs lookup**, not fan-out investigation — it is not a sample of the behavior AC5 asks about |
| 3 | 2026-09-09 | 49 inline results >= 2k tok, 7 sessions | **0 of 49 delegated** | absorbed inline | n/a | **100%** of them cleared the 24,650 break-even (`tok x turns_resident`); largest 6,124 tok resident 1,233 turns = 7.5M |

Row 3 is the one that makes row 1 mean something. Zero delegations against zero
opportunities would be a quiet corpus; zero against 49 qualifying ones is a
statement about the guidance. The guidance was also **loaded** — the string
`delegating-investigation` appears in 12 of the 13 session transcripts — so this
is not a discoverability gap at the skill-loading layer.

Reproduce:

```bash
plugins/workflow/scripts/delegation-adoption.sh adoption
plugins/workflow/scripts/delegation-adoption.sh opportunities
plugins/workflow/scripts/delegation-adoption.sh ac5
```

The absolute spawn counts are local-machine figures, not fleet spend, so § *Why
no absolute figures* does not bite: publishing "118 spawns on one dev box"
discloses no org-wide volume. The token figures stay as ratios and per-item
sizes.

## Per-model windows

| window | opus req share | opus cost share | fleet avg prompt/req | reconcile delta | notes |
| --- | ---: | ---: | ---: | ---: | --- |
| 2026-08-22T18:00Z .. 2026-08-23T18:00Z | 41.9% | 80.7% | 151,739 | 0 | #781 baseline (before) |
| — | — | — | — | — | **AC6 DEFERRED — no after-window; see below** |

**AC6 is deferred, not failed.** `BIFROST_URL` is unset in every environment
this issue could reach, and `token-report.sh` correctly **refuses** rather than
emitting a window (it names the variable and warns that `ANTHROPIC_BASE_URL` is
the wrong root, whose `/api/logs/stats` answers HTML with HTTP 200). No after-row
was fabricated, and none is inferred from the local transcripts: those measure
one machine, while the baseline row is fleet-wide, and pairing them would produce
exactly the kind of plausible-but-wrong comparison the reconciliation guard in
that tool exists to prevent.

Note also that AC6 has been **made moot in its original form** by the adoption
finding. It asks whether opus's token share fell *because* investigation moved to
sonnet subagents. With zero such delegations there is no mechanism for it to have
moved, so any share change in a future window would be attributable to something
else. Re-run AC6 **after** adoption is non-zero, or the measurement answers a
question about a cause that was not operating:

```bash
export BIFROST_URL=<gateway ADMIN root>        # NOT ANTHROPIC_BASE_URL
TR=plugins/workflow/scripts/token-report.sh
"$TR" window --start 2026-08-22T18:00:00Z --end 2026-08-23T18:00:00Z > /tmp/baseline.tsv
"$TR" window --start <after-start> --end <after-end> > /tmp/after.tsv
"$TR" compare --baseline /tmp/baseline.tsv --compare /tmp/after.tsv --percent-only
```

## Verdict

**The guidance did not fire. Recall is untested, not intact.**

What the data **does** establish:

- **Adoption is zero.** Across 118 spawns in 13 sessions over a window opening
  two weeks post-merge, **no session delegated a fan-out investigation**. 117
  spawns are review-harness fan-out; the single direct spawn was a
  documentation lookup.
- **The opportunities existed.** 49 inline investigation results were large
  enough to size, and **all 49** cleared the guidance's own break-even. The
  guidance was loaded in 12 of 13 sessions. It was available, applicable, and
  unused.

What the data **does not** establish, stated as plainly as the prior art demands:

- **Recall is UNTESTED — not "held", and not even "did not visibly break".**
  `.claude/memory/review-cost-after-2026-07-28.md` earned the second phrasing
  from two real delegations that could have missed something. This tally has
  **zero**. There was nothing to recall, so no evidence about recall was
  produced, in either direction. Anyone later citing this file for a recall claim
  is citing a measurement that did not happen.
- **AC5 is one sample and not the right shape.** The lone direct spawn returned
  ~417 tokens with no `file:line` anchors. Small is the direction AC5 wants and
  unanchored is not, but it was a docs question with no repo location to cite —
  so it is weak evidence about *doc lookups*, and no evidence about the fan-out
  investigations AC5 was written for. n=1 shows direction, never a rate.
- **AC6 is deferred**, per § Per-model windows: no gateway, no after-window, and
  no mechanism for the change it looks for.
- **Nothing here is fleet-general.** One machine, three days, one operator's
  working style. It cannot distinguish "this guidance does not get followed" from
  "it did not get followed *here*, in this period, on this kind of work".

The live finding is **non-adoption**, which is a behavior question rather than a
measurement one and so is tracked as its own issue —
[#978](https://github.com/joshjhall/librarian/issues/978) — rather than absorbed
here.
`delegation-adoption.sh` is the instrument for re-measuring it: a later window
showing a non-zero direct-spawn count is what would reopen the recall question
this tally could not answer.

One property worth keeping when that happens: the tool exits **3** on an empty
corpus rather than reporting "0 delegations". An absent measurement and a
measured zero are different claims, and only the second is evidence — the same
distinction the 77 sentinel draws for a gate whose linter is missing (#538/#571).
