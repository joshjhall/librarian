# Context-budget re-derivation on a 1M-era corpus (#1056)

**Status:** complete. **Date:** 2026-09-16. **Supersedes the *inputs* of**
`context-threshold-tally-784.md`; keeps its method verbatim.

Issue #784 derived `CONTEXT_BUDGET_THRESHOLD=175000` and `CONTEXT_BUDGET_FLOOR=91000`
against a corpus captured 2026-08-24, under a **200k** context window. Every
model a golem now runs on except Haiku has a **1M** window. This re-runs that
derivation on a current corpus.

**Outcome in one line:** the floor moves **91k → 104k**; the threshold stays
**175k**; `R` is now **measured** (n=1) rather than swept.

## Why "the window got bigger, so raise the threshold" is not the answer

Restated here because it is the first thing any reader will reach for, and the
re-derivation confirms it a second time: the window was **never an input**. 175k
is a **cost** optimum, not a capacity limit. The penalty the threshold exists to
counter — context accumulating underneath every subsequent request — is paid at
every size, and a larger window removes a ceiling that was not the binding
constraint. The measurements below reproduce that structure on 1M-era data.

## Corpus

Four sessions, all `claude-opus-5` (the 1M-era model), captured 2026-09-14→16
from one operator and one repo.

| session | n (dedup'd top-level requests) | floor | last |
| --- | ---: | ---: | ---: |
| main checkout A | 389 | 84,369 | 482,408 |
| main checkout B | 232 | 84,537 | 359,582 |
| worktree/golem | 170 | 104,416 | 219,736 |
| worktree (#1056 planning) | 59 | 104,410 | 182,296 |

**This corpus is smaller than #784's (4 sessions vs 28) but current rather than
stale.** That is the whole reason it is worth running: #784's n is better, its
model is not. No figure below should be read as equal in weight to #784's
corresponding figure, and every one carries its n. Where the two disagree, the
disagreement is reported rather than resolved.

Extraction is #784's own recipe — dedup by `message.id`, top-level
(non-sidechain) requests only, price weighting input 1.00 / cache-creation 1.25 /
cache-read 0.10 / output 5.00.

## Finding 1 — the floor is bimodal by session shape

The single ~91k figure does not survive. Floors cluster in two groups,
reproducible to within ~50 tokens inside each:

| shape | floor | n sessions |
| --- | ---: | ---: |
| main checkout | ~84.4k | 2 |
| worktree / golem | ~104.4k | 2 |

A **~24% gap**, and 91k sits *between* the clusters — so the shipped value is
currently wrong for both. The cause is structural: a golem session loads a skill
preamble a plain session does not.

**Decision: the floor moves to ~104k**, the worktree/golem figure, because
`context-budget.sh` exists to serve golem handoffs — that is its caller. The
main-checkout figure (~84.4k) is documented beside it in `config.sh` so the next
reader knows the constant is tuned to one shape deliberately. **No
shape-detection logic is added**: the knob stays a plain constant, preserving the
script's fail-loud simplicity, and it remains env-overridable for anyone whose
sessions floor elsewhere.

One caveat recorded rather than smoothed over: a third worktree session observed
mid-run floored at **96.3k**, between the clusters. The two-cluster reading is
the best fit to n=4, not a law.

## Finding 2 — the decile cost effect, re-confirmed but span-dependent

Price-weighted mean cost per request, last decile over first:

| session | d9/d0 | context span (d9/d0 of mean ctx) |
| --- | ---: | ---: |
| main checkout A | **3.78x** | 3.75x |
| main checkout B | **2.18x** | 3.24x |
| worktree/golem | 1.08x | 1.85x |
| worktree (#1056) | 0.57x | 1.70x |

The effect **survives on the sessions that run long enough to show it** — 3.78x
reproduces #784's headline ~3x almost exactly. The two weak ratios belong to the
two sessions whose context barely doubled; a session that never climbs the curve
cannot exhibit the climb. #784 reported the same pattern for its own low-ratio
sessions.

**Stated as a limit, not a finding:** span-normalizing the ratio
(`(d9/d0)^(1/span)`) yields 1.43 / 1.27 / 1.04 / 0.72 — monotone, not clustered.
So this corpus **cannot cleanly separate** "narrow span" from "worktree shape" as
the explanation; the two are confounded at n=4. What it does establish is that
the effect has **not disappeared** under 1M-era pricing, which is what the
threshold depends on.

## Finding 3 — `R` measured (n=1), converting a swept parameter into an observed one

Issue #784 swept `R` from 3 to 50 because it had no measurement. This run has one.

The corpus contains exactly **one** recorded `verdict=handoff` (worktree session,
197,956 tokens / 113% of threshold) — and **no handoff followed it**: that
session continued to 219,736. So no post-handoff re-orientation sequence exists
anywhere in the observed corpus. *(That non-adherence is a real defect, but a
different one — it concerns whether the skill acts on the verdict, not what the
verdict's threshold should be. Filed separately.)*

`R` was therefore obtained by **instrumenting and performing** a handoff rather
than mining one: the #1056 planning session ended at its plan-approved phase
boundary, writing a `handoff_marker` into its checkpoint; the resumed session
counted its own re-orientation requests before its first file-modifying one.

**R = 3** (strict re-orientation: read the checkpoint + issue, read the approved
plan, locate the corpus and saved filter). Two wider framings are recorded in the
marker so the number is not cherry-picked: **5** counting harness entry, **9**
counting every request before the first edit.

This is **one observation**. It narrows the sweep; it does not replace it — and
the recommendation below is deliberately checked against both the measured
neighbourhood and the blind range.

## Finding 4 — cap simulation and regret sweep

Each session is replayed under a candidate cap: on exceeding it, context resets
to that session's measured floor, one cache-creation charge re-establishes the
cache, and `R` re-orientation requests are spent. Only context-carried components
are rescaled — output tokens are work the session still owes.

Modeled saving vs no cap:

| threshold | R=3 | R=5 | R=10 | R=20 | R=35 | R=50 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 125k | 41.4% | 37.1% | 26.4% | 4.9% | -27.3% | -59.5% |
| 150k | **43.2%** | **41.1%** | 35.7% | 25.0% | 9.0% | -7.0% |
| 175k | 41.7% | 40.2% | 36.2% | 28.3% | 16.4% | 4.5% |
| 200k | 40.4% | 39.4% | **36.8%** | **31.5%** | 23.7% | 15.8% |
| 250k | 35.7% | 35.2% | 34.0% | 31.5% | **27.8%** | **24.1%** |
| 300k | 26.9% | 26.6% | 25.8% | 24.3% | 21.9% | 19.6% |
| 400k | 15.9% | 15.7% | 15.2% | 14.3% | 13.0% | 11.6% |

The #784 structure reproduces: monotonic in tokens alone, an interior optimum
only once re-derivation is priced, and the optimum drifting right as `R` grows.

Worst-case regret, by the range of `R` assumed:

| threshold | blind R=3–50 (#784's situation) | measured-R neighbourhood R=1–10 | R=2–6 |
| ---: | ---: | ---: | ---: |
| 125k | 83.6% | 10.4% | 5.0% |
| 150k | 31.1% | **1.1%** | **0.0%** |
| 175k | 19.6% | 2.3% | 1.7% |
| 200k | 8.3% | 4.2% | 3.3% |
| 250k | **7.5%** | 9.4% | 8.3% |
| 400k | 27.3% | 29.6% | 28.3% |

**The measurement is what makes this tractable.** Blind over R=3–50 the minimax
answer is 250k; knowing `R≈3` collapses the plausible range and moves it to
150k–175k. The two conclusions are not in conflict — they are the same table read
under different uncertainty.

### "But isn't reloading the base context more expensive than running on?"

The most natural objection, and worth answering in magnitudes because it
compares a **one-time** cost against a **per-request** one.

A handoff costs **~161k weighted units, once** — re-establishing the cache at a
104k floor (`104000 × 1.25`) plus R=3 re-orientation requests read from cache.
That is genuinely expensive, which is the whole reason the threshold is not at
the floor.

But a request carrying 175–200k of context costs **~8–11k units more** than the
same request at the floor:

| session | surcharge per request above 175k | break-even | requests actually spent in 175k–250k |
| --- | ---: | ---: | ---: |
| main checkout A | +8.2k | 19.7 | 85 |
| main checkout B | +10.7k | 15.1 | 38 |
| worktree/golem | +9.7k | 16.5 | 92 |
| worktree (#1056) | +0.3k | 641 | 11 |

So running on from 175k to 250k does not *save* the 161k — it spends ~9k extra
on **every** request in that band, 2–5x the reload cost for the three sessions
that get there.

**The fourth row is the honest limit**, and it is why `handoff` is advisory
rather than enforced: a session that will finish shortly should not hand off,
because it never reaches break-even. The rule the numbers actually support is
*the accumulation beats the reload only if you will keep working long enough to
pay it* — which is a statement about remaining work, not about context size
alone. A caller that force-cycled on the verdict would be wrong for that row.

## Decision

**`CONTEXT_BUDGET_FLOOR`: 91000 → 104000.** Finding 1; tuned to the golem caller.

**`CONTEXT_BUDGET_THRESHOLD`: unchanged at 175000.** This is a legitimate
outcome, not a failure to deliver, and it is chosen on two grounds:

1. **Regret.** At the measured `R`, 175k costs **1.5pp** against the best
   (150k) — and 150k's advantage evaporates immediately if the true `R` is
   higher than one observation suggests (at R=10 it is *behind* 175k, at R=20 by
   3.3pp). 175k loses at most 2.3pp anywhere in R=1–10 and stays the robust
   choice.
2. **The working band, which the floor move changes.** The floor rising to 104k
   narrows the gap between where a fresh session starts and where it must hand
   off. Handoffs actually taken by the corpus sessions:

   | floor / threshold | band | main A | main B | golem | #1056 |
   | --- | ---: | ---: | ---: | ---: | ---: |
   | 91k / 175k (old) | 84k | 4 | 3 | 1 | 1 |
   | **104k / 175k (new)** | **71k** | 5 | 3 | 1 | 1 |
   | 104k / 150k | 46k | 8 | 5 | 2 | 1 |

   Dropping to 150k would nearly **double** the handoff count for ~1.5pp of
   modeled saving, each handoff carrying real costs the model does not price
   (lost working context, re-orientation error). A 46k band is too tight to run a
   golem in.

**AC6 — should the default scale with the detected window? No.** The
re-derivation is the evidence: the optimum did **not** move when the window grew
5x, exactly as the issue predicted, because the window was never an input.
Scaling from the detected window would tie a cost optimum to a capacity number
it does not depend on, and would hand Haiku and Opus different tunings for a
difference that does not affect the tradeoff. The variation that *does* matter is
session **shape** (Finding 1), which is why the floor moved and the threshold did
not. Revisit if long-context pricing changes; the env override covers anyone who
disagrees today.

## Instrumentation added (AC2, for the next run)

`R` should not need hand-counting again. The `checkpoint` object gains an
optional `handoff_marker` — no new state format, per `handoff-protocol.md` §
"The handoff", the same way `scope_expansions` was added for #756:

- **Write side.** A golem acting on a `handoff` verdict records the
  `context-budget.sh` output it already has in hand (`context_tokens`,
  `threshold`, `floor`, `pct_of_threshold`, timestamp). No new measurement.
- **Read side.** The resumed session counts its own requests before the first
  productive one and fills `r_measured`.
- **Fail-open.** A missing marker degrades to "R unknown", never to an error or a
  blocked resume. It is telemetry; it must not gate the handoff it observes.

## Limits

- **n=4 sessions, one operator, one repo, one model.** #784 had 28. Treat every
  figure here as current-model evidence, not as a better-powered replacement.
- **`R` is n=1**, self-measured by the session performing the handoff.
- **Simulated, not observed.** The cap replay models what each session *would*
  have cost; no session was actually run under a different threshold.
- **Span and shape are confounded** in Finding 2 (see the stated limit there).
- #784's own limits section anticipated exactly this re-run.

## Reproduction

```bash
# Per-request usage components, deduped, top-level only (#784's filter plus
# raw components so the sim can rescale context without shrinking output cost):
jq -R -s -f extract.jq "$HOME/.claude/projects/<project>/<session>.jsonl"
```

Then replay: for each candidate cap, walk the request series; when
`ctx - offset > cap`, add `floor * 1.25` plus `R *` the mean cost of the five
cheapest requests, and set `offset = ctx - floor`. Score each cap by savings vs
the uncapped total; take the max-over-R of (best-at-that-R − this-cap) for
worst-case regret.
