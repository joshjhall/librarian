---
name: review-cost-baseline-2026-07-28
description: "BASELINE: measured ship-issue review cost before the #553/#550/#551 changes — per-cycle and per-dimension, for before/after comparison"
metadata: 
  node_type: memory
  type: project
  originSessionId: b03da476-855a-4340-a1de-499a566aea26
  modified: 2026-07-28T20:52:03.822Z
---

Frozen baseline of the ship-issue adversarial review harness **before** any
cost work landed. Recorded 2026-07-28 so post-change runs have something honest
to compare against. Do not edit these numbers — add a sibling file for the
"after" measurement.

## Provenance

Session `b472b132-b2dd-4c1e-b549-e5fb7417f5b6`, the #471/#472 ship (PR #547).
Three review cycles, all 7 agents each (narrowing never engaged). Transcripts:
`~/.claude/projects/-workspace-librarian/b472b132-*/subagents/workflows/wf_*/`.

Code state: `main` at `a8b23c7`, i.e. **no** `tokenCeiling`, **no**
`SCOPE_DISCIPLINE`, **no** pre-scan handoff.

**All figures deduped by `message.id`.** Raw summation runs ~2× high (cycle 2
raw cache_read 34.3M vs deduped 16.9M) — see [[token-scrape-transcript-dedup]].
An earlier pass in this session reported the RAW numbers by mistake; the table
below is the corrected one.

## Per-cycle totals

| Cycle | workflow | files | agents | cache_read | cache_write | output |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | wf_9fb83752 | 2 | 7 | 6.25M | 352k | 173k |
| 2 | wf_02c311e6 | 2 | 7 | 16.93M | 433k | 281k |
| 3 | wf_5300fbc5 | 5 | 7 | 8.99M | 428k | 207k |
| **total** | | | **21** | **32.2M** | **1.21M** | **660k** |

Top-level session (orchestrator, not agents): 52.9M cache_read / 126k output
across 212 deduped messages. Whole-session cache_read is therefore ~85M; the
harness agents are ~38% of it.

Cycle 2 cost 2.7× cycle 1 on the **same 2-file diff** — cost tracks in-agent
exploration, not diff size. This is the central finding.

## Per-dimension (turns / output / cache_read / Bash calls)

Cycle 1 — bug 48/59.6k/2.47M/40 · conventions 37/43.1k/2.08M/37 ·
security 24/47.1k/1.14M/18 · tests 9/15.1k/349k/7 · scope-drift 5/2.5k/121k/4 ·
judge 3/5.3k/55k/2 · manifest 2/0.4k/24k/0

Cycle 2 — **security 128/139.9k/9.59M/115** · conventions 63/44.0k/3.58M/63 ·
tests 42/36.6k/2.18M/35 · bug 25/50.1k/1.30M/16 · scope-drift 9/5.3k/263k/8 ·
manifest 2/1.6k/24k/0 · judge 1/3.2k/0/0

Cycle 3 — bug 55/58.2k/3.62M/51 · tests 40/84.8k/2.63M/47 ·
conventions 28/33.4k/1.72M/29 · security 13/17.3k/638k/11 · judge 7/8.2k/177k/9 ·
scope-drift 7/1.8k/180k/6 · manifest 2/2.9k/24k/0

## What the shape says

- **Bash calls ≈ turns** for every reviewer (security cycle 2: 115 Bash of 128
  turns). Each call re-sends accumulated context, so cache_read scales with tool
  calls, not with diff size. **cache_read per Bash call is ~50-80k** — that is
  the unit cost to attack.
- **No `Grep` at all; Read is rare** (≤12 per agent). Reviewers explore by
  shelling out, not by the cheap structured tools.
- **Variance is enormous and not diff-driven**: security ranges 13→128 turns
  across three cycles of nearly the same change. Any fixed token ceiling is
  therefore guessing against a wide distribution — the reason #553 shipped the
  ceiling OFF by default.
- **Cost ranking is unstable.** bug tops cycles 1 and 3; security tops cycle 2
  by 3×. Do not demote a dimension on one cycle's ranking.
- **scope-drift, manifest, judge are already cheap** (≤9 turns). Nothing to win
  there; leave them alone.
- **conventions is consistently mid-high (28-63 turns) with bash≈turns** — it
  re-reads CLAUDE.md / AGENTS.md / `.claude/memory/*.md` on every run, in every
  dimension. That is the most clearly redundant work in the fan-out.

## Cost model in the operator's terms

The "100-200M tokens per run" figure is **cache_read**, billed at ~0.1× base.
Real output for a full 3-cycle review is **660k**. Both matter, but the lever is
cache_read, and cache_read is a function of tool calls.

## The "after" measurement is tracked in #559

Issue #559 holds the full question list, the collection recipe, and the
pass/fail criteria. Record results in a sibling `review-cost-after-<date>.md`
and link it here. **First check on any post-change run:** the harness logs
`pre-scan: none supplied` / `conventions digest: none supplied` when the caller
did not pass the new args — such a run is a re-run of THIS baseline, not a test
of #556/#557.

## What to compare after the changes land

Post-change, every cycle emits `token_report`
(`{output_tokens, ceiling, bound, dimensions_run}`) and logs
`cycle output: N tokens across M dimensions` — so the "after" numbers no longer
need transcript archaeology. Compare:

1. **Bash calls per reviewer** — the direct target of `SCOPE_DISCIPLINE` (#553)
   and the pre-scan handoff. Expect security/conventions to fall most.
2. **cache_read per cycle** — the real money.
3. **Cycles to clean** — must NOT increase. If bounding makes reviews miss
   things, the loop runs more cycles and the change is cost-negative.
4. **Findings count and severity mix** — the recall check. Cheaper reviews that
   find less are not a win.

Related: [[issue-553-review-token-ceiling]], [[token-burn-audit-2026-07-21]],
[[token-scrape-transcript-dedup]], [[issue-256-cache-stability]]
