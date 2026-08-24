# Context-handoff threshold — derivation (#784)

**Status: OPEN — the derivation is complete; the before/after window is not.**
This file records how the 175k handoff threshold in `CONTEXT_BUDGET_THRESHOLD`
was derived (issue #784 AC2), and stays open until a comparable golem run is
measured against the #781 baseline (AC6). Per CLAUDE.md § `docs/verification/`
this is the running-tally shape, closed with a verdict once that window lands.

**Figures are NORMALIZED, deliberately** — ratios, percentages, and per-request
token counts only, no absolute request counts or dollar totals. Same reasoning as
`token-baseline-tally-781.md` § *Why no absolute figures*: this repo is public,
and a ratio is exactly as good a before/after anchor as an absolute while
disclosing nothing.

## The corpus

28 local Claude Code session transcripts (`~/.claude/projects/**/*.jsonl`), all
sessions with ≥ 50 top-level requests, captured 2026-08-24. Per-request context
size is

```text
input_tokens + cache_read_input_tokens + cache_creation_input_tokens
```

on each top-level (`isSidechain != true`) record, deduplicated by `message.id` —
Claude Code writes one transcript line per assistant *content block*, and every
line of a turn repeats that turn's usage, so an undeduplicated read multi-counts
by block count (the same trap `golem-token-scrape.sh`'s header documents).

## Finding 1 — the measured floor is ~91k, not 78k

The first top-level request of a session — the system prompt, tool definitions,
and skill preamble a fresh session re-pays before doing anything — measured
**~91k tokens**, consistently, across every session that had not been resumed
mid-stream.

This **supersedes the 78k figure in #784's body**, and it matters: the floor is
what a handoff *costs*, so it is the denominator of the whole crossover question.

## Finding 2 — the 3x decile effect reproduces, price-weighted

The issue's headline claim was derived from raw input volume. Weighting each
request by what it actually costs — fresh input 1.00, cache creation 1.25, cache
read 0.10, output 5.00, relative to base input price — the effect survives:

| statistic | decile-9 ÷ decile-0 cost per request |
| --- | ---: |
| minimum | 1.07× |
| median | **~3.0×** |
| maximum | 5.34× |

Same work, same session, 3x the price — purely because context had grown
underneath it. The sessions clustering near 1.0x are the short ones that never
grew; the long sessions are uniformly 2.5–5.3x.

## Finding 3 — token cost alone cannot pick a threshold

Simulating a cap at threshold T (on crossing T, the session hands off; remaining
requests replay from the floor and re-accumulate, paying one cache-creation
charge to re-establish the floor):

| threshold | modeled saving |
| ---: | ---: |
| 150k | 45.3% |
| 200k | 37.7% |
| 250k | 29.8% |
| 300k | 24.3% |
| 400k | 13.8% |

**Monotonic.** Cycling sooner always wins, all the way down to the floor, so
sweeping pure token cost returns "cycle immediately" — which is obviously wrong
and is why the issue's own framing ("cycling too eagerly costs more than it
saves") cannot be settled on token accounting alone.

## Finding 4 — pricing the handoff yields a real optimum

The missing term is **re-derivation work**: each handoff buys R requests of
re-orientation — re-reading the state file, the plan, and the files already read
— that produce no progress. Modeled at R requests per handoff, each at ~1.5x
floor context, total cost = token cost + handoff overhead:

| threshold | token cost | overhead | total saving (R=10) |
| ---: | ---: | ---: | ---: |
| 125k | — | — | 36.5% |
| 150k | — | — | **40.2%** |
| 175k | — | — | 37.3% |
| 200k | — | — | 35.1% |
| 250k | — | — | 28.3% |
| 400k | — | — | 13.4% |

An interior optimum, as expected. But R is itself an estimate, so the optimum
must not depend on guessing it correctly:

| R (re-orientation requests per handoff) | best threshold |
| ---: | ---: |
| 3 | 150k |
| 5 | 150k |
| 10 | 150k |
| 15 | 150k |
| 20 | 150k |
| 30 | 175k |
| 50 | 200k |

## The choice — 175k, by minimax regret

Picking the R=10 optimum (150k) would be tuning to one guessed parameter. Instead
each candidate is scored by its **worst-case shortfall** against the best
achievable saving, across the whole R sweep:

| threshold | worst-case regret |
| ---: | ---: |
| 125k | 27.4% |
| 150k | 6.1% |
| **175k** | **4.1%** |
| 200k | 6.9% |
| 250k | 14.5% |
| 300k | 19.8% |
| 400k | 30.1% |

**175k minimizes worst-case regret.** It is never the best choice for any single
R, and it is never much worse than the best for any R — which is the property
worth having when the parameter is genuinely uncertain.

### This contradicts the issue body, and the contradiction is the point

Issue #784 proposed 250–300k, reasoning from a 78k floor. Both inputs are
superseded:
the floor measured ~91k, and the crossover the issue described cannot be located
by the method it implied (Finding 3). AC2 asks for a threshold **derived** from
measured data rather than picked by hand, so the derivation governs. At 250k the
worst-case regret is 14.5% — 3.5x that of 175k.

Both knobs are env-overridable (`CONTEXT_BUDGET_THRESHOLD`,
`CONTEXT_BUDGET_FLOOR`), so retuning is a variable rather than an edit. Retune
from this derivation, not from a round number.

## Limits of this derivation

Worth stating plainly, since the number will outlive the session that produced
it:

- **One machine, one operator, one repo.** The corpus is this fleet's sessions.
  A team whose sessions start from a much larger or smaller floor should re-run
  the derivation rather than inherit 175k.
- **The overhead model is a model.** "R requests at ~1.5x floor" is a
  parameterization of re-orientation cost, not a measurement of it. That is
  exactly why the choice is made by minimax regret over R rather than by
  optimizing at one R — the conclusion is designed to survive the model being
  somewhat wrong.
- **Simulated, not observed.** Findings 3 and 4 replay real transcripts under a
  counterfactual cap. The real before/after is AC6, still open below.

## Reproducing

```bash
# Per-session context growth (floor, median, last, max)
jq -s -r '[ .[] | select((.isSidechain // false) == false)
            | select(.message.usage != null)
            | { id: (.message.id // "x"),
                c: ((.message.usage.input_tokens // 0)
                    + (.message.usage.cache_read_input_tokens // 0)
                    + (.message.usage.cache_creation_input_tokens // 0)) } ]
          | group_by(.id) | map(.[0].c) as $c
          | "\($c|length)\t\($c[0])\t\($c[-1])\t\($c|max)"' \
   ~/.claude/projects/*/*.jsonl
```

The decile-cost, cap-simulation, and regret sweeps are the same corpus under the
weightings stated above; each table names its parameters, so they re-derive from
that one query plus the arithmetic described in each finding.

## AC6 — before/after (OPEN)

The headline metric is `avg_prompt_per_request`, per #781. Measuring it needs
`BIFROST_URL` and a comparable golem run under the new policy, so it lands as an
appended window here rather than blocking this change:

```bash
export BIFROST_URL=https://bifrost.example
plugins/workflow/scripts/token-report.sh window --start <ISO> --end <ISO>
plugins/workflow/scripts/token-report.sh compare \
  --baseline <pre.tsv> --compare <post.tsv> --percent-only
```

Use `--percent-only` for anything recorded here — it prints percentage deltas
alone, which is what this file publishes.

**Expected direction:** average prompt tokens per request should fall, because
the cap removes the top of every session's context distribution. It should NOT
fall by the full modeled 37% — the model omits the re-orientation requests a real
handoff pays, which is the same term Finding 4 prices in. A measured drop
materially *larger* than modeled is a signal something else changed (a workload
shift, a model-mix change), not a win to bank.
