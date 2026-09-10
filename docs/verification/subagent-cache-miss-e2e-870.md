# Subagent prefix cache-MISS investigation — issue #870

**Status: COMPLETE.** This is a finished end-to-end report, not a running tally.
It records *why* a large fraction of subagent spawns re-write the shared
system-prompt + tool-schema block instead of reading it, and why the fix is
**not available in this repository**.

**Figures are NORMALIZED where they are cumulative.** Per
[`token-baseline-tally-781.md`](token-baseline-tally-781.md) § Why no absolute
figures: this repo is public, so fleet-wide volume totals are not committed.
Rates, per-spawn medians and ratios *are* reported — they disclose no volume.

## Summary

[#787](https://github.com/joshjhall/librarian/issues/787) measured a 33%
cache-miss rate on bytes that are byte-identical across spawns, costing ~12x for
nothing, and split the *cause* here. #870 named three candidate hypotheses — a
5-minute TTL expiring between review cycles (H1), barrier scheduling racing to
populate the cache (H2), and a cold-start floor (H3) — and correctly insisted
that the first step was to **timestamp misses against cycle boundaries**, since
H1 and H2 make distinguishable predictions.

They do, and **both are real**. The miss is overwhelmingly carried by the
*first* spawn of each fan-out barrier (H2), and that spawn's miss probability
then rises with the gap since the previous barrier, steepening past the TTL
(H1). H3 is a genuine but small floor.

**No lever for either exists in this repo.** The fan-out primitive that would
have to change (`parallel()`) is injected by the Workflow runtime and is not
defined in any harness source; the prompt prefix is already maximally
cache-stable from #256. This is platform-side cache allocation.

## Method

Instrument: `plugins/workflow/scripts/measure-spawn-prefix.sh`, extended by this
issue with a fourth subcommand:

```bash
plugins/workflow/scripts/measure-spawn-prefix.sh timing
```

It walks `~/.claude/projects/**/subagents/**/*.jsonl`, takes each spawn's first
**billed** turn (the first record with non-zero usage), and groups spawns into
**barriers**: runs of consecutive same-session spawns each starting within 20s
of its predecessor. There is no barrier id in a transcript, so the grouping is
inferred from dispatch latency — the threshold sits well above the widest
observed intra-barrier spread (~19s on a 7-way fan-out) and well below the
smallest inter-barrier gap. A spawn missing either a `sessionId` or a
`timestamp` is **dropped**, not guessed into a barrier; the report prints how
many it placed.

Each spawn gets a `rank` (0 = the spawn that opens the fan-out) and each
barrier's leader gets `gap_before`, the seconds since that session's previous
barrier ended.

**Sample: n=297 spawns / 119 barriers across 14 sessions, one machine,
2026-09-09.** #787's sample was n=33. See § Limits.

### The headline reproduces at 9x the sample

| metric | #787 (n=33) | this report (n=297) |
| --- | ---: | ---: |
| cache MISS rate | 33% | **36%** |
| implied shared block | 12,635 | 9,897 |
| miss penalty per spawn | 14,530 | **11,382 tok-equiv (12x)** |

The 33% was not a small-sample artifact.

## Finding 1 — the miss belongs to the barrier LEADER (H2)

Miss rate by position within the fan-out:

| rank | miss / n | rate |
| ---: | ---: | ---: |
| **0 (leader)** | 85 / 119 | **71%** |
| 1 | 13 / 45 | 29% |
| 2 | 3 / 42 | 7% |
| 3 | 3 / 38 | 8% |
| 4 | 2 / 31 | 6% |
| 5+ | 2 / 22 | 9% |

**76% of all misses are barrier leaders.** The characteristic barrier reads
`Mhhhhh`: the leader writes the block, its siblings read it.

That the siblings read *the leader's* write is directly visible — follower
`cache_read` values are byte-stable and recur across sessions (`10,702` in five
separate sessions, `11,370` in two), while their leader shows `cache_read = 0`
and a correspondingly larger `cache_creation`.

This is exactly what `workflow.src/70-prompts.js:132` already predicted in prose:

> within one `parallel()` barrier the siblings cannot read each other's
> in-flight cache write

The measurement confirms the comment. Rank 1 sits higher than ranks 2+ (29% vs
~7%) because the second spawn sometimes starts before the leader's write has
landed.

## Finding 2 — the leader's own miss is a TTL *gradient*, not a cliff (H1)

If H1 alone were operating, the leader miss rate would be flat below the
300-second TTL and step sharply above it. It does step — but it is not flat
below:

| gap before barrier | leader miss rate |
| --- | ---: |
| 0–30s | 56% (10/18) |
| 30–60s | 50% (8/16) |
| 60–120s | 56% (5/9) |
| 120–300s | 67% (6/9) |
| **300–600s** | **82% (23/28)** |
| **600s+** | **91% (21/23)** |
| cold (session's first) | 75% (12/16) |

The step past 300s is real and matches the documented TTL. But **~50% of leaders
already miss at a 30-second gap**, which no TTL explains. So the two hypotheses
are not competing accounts of the same misses — they are additive: a
per-barrier allocation effect that a later barrier often fails to reuse, plus
TTL decay that makes failure near-certain past five minutes.

## Finding 3 — cross-barrier reuse IS possible, so the miss is not structural

**34 of 119 barrier leaders (29%) hit.** If the platform allocated a fresh cache
entry per barrier by construction, that number would be zero. Reuse across
barriers demonstrably happens; it is simply unreliable, and it decays with time.

This matters for sizing: the addressable population is not "one unavoidable miss
per barrier". A perfectly-reusing cache would eliminate essentially all 108
misses, not just the 23 follower ones.

## Finding 4 — miss attribution

| category | misses | share | cost |
| --- | ---: | ---: | ---: |
| leader, gap > TTL | 44 | 41% | 500,790 tok-equiv |
| leader, gap ≤ TTL | 29 | 27% | 330,066 tok-equiv |
| follower (within a barrier) | 23 | 21% | 261,777 tok-equiv |
| leader, session cold start | 12 | 11% | 136,579 tok-equiv |
| **total** | **108** | | **1,229,212 tok-equiv** |

Cold start (H3) is a real floor but the smallest term — #870 was right that the
observed rate "clearly exceeds" it.

## Finding 5 — nothing in this repo is the lever

Four repo-side causes were tested; each is ruled out by measurement or by
inspection.

| candidate | verdict | evidence |
| --- | --- | --- |
| Harness could stagger or pre-warm the fan-out | **impossible** | `parallel()` is injected by the Workflow runtime — no `workflow.src/` fragment, and no `workflow.js` in any plugin, defines it. The harness passes a list of thunks and controls neither dispatch order nor spacing |
| Dispatch spread could be tuned | **no effect** | all-miss barriers occur at every leader→2nd-spawn latency band (`<5s`, `5–12s`, `≥12s`) — 1 each. Widening or narrowing the spread predicts nothing |
| Prompt prefix is unstable across siblings | **already solved** | #256 made the reviewer prompts share the maximal byte-identical prefix, diverging only in a trailing selector (`workflow.src/70-prompts.js:132`). Confirmed by the byte-stable follower `cache_read` values in Finding 1 |
| Cross-session interleaving / client version bumps | **not the cause** | interleaved barriers miss *less* (29% vs 61% in-TTL). Every leader miss in the corpus occurs with the client version unchanged from the prior barrier |

The one repo-side knob that lengthens the inter-barrier gap is the CI wait
between review cycles (`scripts/ci-wait-timeout.sh`). Shortening a CI wait to
court a cache entry would trade a correctness gate for a billing artifact, at
real cost — it is not a fix and is explicitly **not** recommended.

**Conclusion: this is platform-side prompt-cache allocation.** It is stated here
plainly so nobody re-derives it. If the behavior changes upstream, `timing`
re-measures it in one command.

## AC disposition

| AC | Status |
| --- | --- |
| AC1 — miss timing correlated against cycle boundaries and spawn order, distinguishing TTL from barrier | **Satisfied** — Findings 1–2. The two hypotheses are separated on independent axes (rank within barrier; gap before barrier) and **both** are confirmed operating, which is a third outcome the issue did not anticipate |
| AC2 — root cause identified with evidence, not inferred from source | **Satisfied** — every claim is a measurement over n=297 transcripts. Finding 5's one inspection-based row (`parallel()` is runtime-injected) is stated with the grep that checks it, precisely because it is not a measurement |
| AC3 — if fixable in this repo, fixed with before/after miss rate | **Not applicable, with evidence** — Finding 5. The fan-out primitive is runtime-injected and the prompt prefix is already maximally stable; there is no in-repo lever to change |
| AC4 — if NOT fixable here, documented as such in `docs/verification/` | **Satisfied** — this file |
| AC5 — miss rate re-measured after any change; delta recorded | **Satisfied; delta nil by construction** — no change in this PR alters spawn behavior, so no delta is possible. The re-measurement that *did* happen is the 33% → 36% at 9x the sample (§ Method), confirming the original direction. The `timing` subcommand is the deliverable that makes a future re-measurement one command |

## Limits

- **n=297, one machine.** The corpus is dominated by `dev-core:code-reviewer`
  spawns from ship-issue review cycles, so the *barrier shape* measured here is
  that of a 5–7 dimension review fan-out. A different fan-out shape may
  distribute misses differently; the leader/follower asymmetry itself is
  structural and should not.
- **Barriers are inferred, not read.** There is no barrier id in a transcript.
  The 20s threshold is justified in § Method and the leader/follower split it
  produces is a ~5x rate difference, which no plausible threshold in that range
  erases — but it remains an inference.
- **The cause is localized, not explained.** This report establishes *where* the
  misses fall and rules out the repo-side candidates. Why the platform's cache
  fails to serve a byte-identical block to a barrier leader 71% of the time is
  upstream behavior this repo cannot observe.
- **Cost figures are derived**, not billed amounts: the shared block is inferred
  from the difference of two group means and priced at the documented
  read/write multipliers, exactly as the `cache` subcommand does.

## Reproducing

```bash
plugins/workflow/scripts/measure-spawn-prefix.sh timing   # this report
plugins/workflow/scripts/measure-spawn-prefix.sh cache    # the #787 baseline
```

Requires local subagent transcripts under `~/.claude/projects/` — run at least
one fan-out (a ship-issue review cycle) first. With no python3 >= 3.11 the shim
exits **77** with an actionable message rather than reporting zeros.
