# #550 — routed-cycle cost measurement

Evidence for issue #550's AC4: *"Measured cost on a 2-file diff drops materially
vs the table above."* Captured 2026-09-04 during this issue's own ship run.

## Why this file exists

The other three ACs are pinned by tests. AC4 is a **quantitative** claim, and a
dimension count is not a measurement — so it is recorded here rather than
asserted in a suite that cannot observe token spend.

## Baseline — the full fan-out (from #550's issue body, #471/#472 run)

| Cycle | files | cache_read | output |
| ----- | ----- | ---------- | ------ |
| 1 | 2 | 13.0M | 367k |
| 2 | 2 | 34.3M | 578k |
| 3 | 5 | 19.8M | 468k |

## Measured — this PR's own review cycles (full route, 16 files)

Every cycle below ran `reviewRoute: "full"`, because the router classified this
PR's own diff as source-bearing (`R2-source`, 11 source files). They are the
control, not the treatment.

| Cycle | agents | subagent tokens | tool calls | wall |
| ----- | ------ | --------------- | ---------- | ---- |
| 1 | 8 | 671,405 | 256 | 25m |
| 2 | 8 (judge never ran) | — wall-timeout, stopped at 40m ceiling | — | 40m+ |
| 3 | 8 | 762,112 | 314 | 25m |
| 6 | 8 | 767,360 | 276 | 22m |
| 7 | 8 | 744,071 | 281 | 23m |

All measured pre-#551, hence eight agents.

## The routed path — structural measurement

A `cheap` cycle was not exercised end-to-end here, because this PR's diff
correctly refuses to route cheap. What *is* measured is the agent count the
route produces, verified against the **generated artifact** (not the fragments):

```text
route=cheap  -> dims=decomposition,scope-drift                    (2 dimensions)
route=full   -> dims=security,correctness,tests,
                     decomposition,scope-drift                    (5 dimensions)
```

**Re-derived against the post-#551 baseline.** #551 (PR #912) demoted
`conventions` to a scheduled audit, so the default set is five dimensions, not
six. Every figure below was recomputed against that — the earlier drafts of this
file cited a 3-vs-8 comparison from the six-dimension shape and were wrong
once #551 landed.

`decomposition` survives the cheap path because its `DIMENSION_RELEVANT_TYPES`
entry lists `docs`; the selector derives that rather than hardcoding a list.

Per-cycle agent totals are `manifest + dimensions + judge`:

| Route | agents | vs full |
| ----- | ------ | ------- |
| full  | 7 | — |
| cheap | 4 | **−43%** |

The two cycles measured above spent 671k and 762k subagent tokens, but across
the **eight**-agent pre-#551 shape, so they are not a clean denominator for the
current seven-agent full route. Treat them as order-of-magnitude context, not as
the baseline for the −43%. The honest figure available today is the agent-count
ratio; the token ratio needs a measured cheap cycle.

## Honest limitation

This is a structural measurement plus a control, not an observed cheap-path
token report. Capturing the latter needs a doc-only PR shipped through the full
pipeline after this lands. **Open item:** attach a real `token_report` from the
first cheap-routed cycle to this file, at which point AC4 is closed empirically
rather than by argument.

## What the measurement bought

The review that produced the control data also found two real classifier holes
(CI/container files and database-shaped paths misrouted as inert config), both
fixed in this PR. That is orthogonal to AC4 but worth recording: the cost of the
full fan-out is what caught the bug in the thing designed to skip it.
