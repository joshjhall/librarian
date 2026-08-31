# Subagent spawn-prefix measurement — issue #787

**Status: COMPLETE.** This is a finished end-to-end report, not a running tally.
It records what the subagent spawn prefix actually costs, and why
[#787](https://github.com/joshjhall/librarian/issues/787)'s prescribed remedy —
narrowing broad `tools:` declarations — turned out to address a cause that is not
present in this repo.

**Figures are NORMALIZED where they are cumulative.** Per
[`token-baseline-tally-781.md`](token-baseline-tally-781.md) § Why no absolute
figures: this repo is public, so fleet-wide volume totals are not committed.
Per-spawn medians and ratios *are* reported — they disclose no volume, and the
24,568 median is already in committed prose
(`delegating-investigation/SKILL.md`).

## Summary

The issue asked for AC1–AC3: audit 38 agents' `tools:` declarations, narrow the
broad ones, check MCP contribution. **There was nothing to narrow.** The prefix
is not driven by tool-declaration breadth. Two levers the issue never named
carry the actual cost.

## Method

Instrument: `plugins/workflow/scripts/measure-spawn-prefix.sh` (shipped by this
issue; Python 3.11+ primary, fail-loud shim, no bash fallback — it parses JSONL).

```bash
plugins/workflow/scripts/measure-spawn-prefix.sh summary   # prefix stats
plugins/workflow/scripts/measure-spawn-prefix.sh split     # cached vs written
plugins/workflow/scripts/measure-spawn-prefix.sh cache     # hit/miss penalty
```

It walks `~/.claude/projects/**/subagents/**/*.jsonl`. A spawn's **prefix** is
the input context of its first billed turn — the first record carrying non-zero
usage — i.e. system prompt + tool schemas + dispatch prompt, sent before the
agent does any work. `agentType` comes from each transcript's `.meta.json`.

**Sample: n=33 spawns on one machine, 2026-08-31.** The issue's figures were
n=301 fleet-wide. See § Limits.

## Finding 1 — the issue's premise does not hold in this repo

Every row below is a **repo fact**, verifiable by inspection and independent of
sample size.

| #787's premise | What the repo actually contains | How verified |
| --- | --- | --- |
| 38 agents across 3 plugins | **19** agent files — dev-core 6, review-audit 10, workflow 3 | `ls plugins/*/agents/*.md` |
| Agents declare `Tools: *` or broad lists | **All 19 declare a narrow explicit `tools:` list. Zero use `Tools: *`** | `grep -rn '^tools:' plugins/*/agents/` |
| `Task` inherited by agents that never use it | All **8** `Task`-declaring agents genuinely batch-dispatch; each documents a "Batch Sub-Agent Dispatching" workflow and a rationale row | read each agent body |
| MCP schemas ride along in every agent | librarian configures **no** MCP: no `.mcp.json`, no `mcpServers` in any agent frontmatter, no agent body references an MCP tool | repo-wide grep |
| Harnesses may spawn broad agents | Every `agentType` in every `workflow.js` targets one of the 19 narrow agents (`dev-core:code-reviewer`, `review-audit:checker`, `review-audit:artifact-writer`, `review-audit:issue-writer`, `workflow:ci-fixer`, `workflow:rebase-agent`) | `grep -rn agentType plugins/` |

**The decisive measurement:** `dev-core:code-reviewer` declares a *narrow*
9-item tool list and still shows a **29,288-token median prefix** (n=32). A
narrow list does not buy a small prefix. Conversely the single `general-purpose`
spawn observed cost **49,919** — ~21k more — so agent *breadth* does matter, but
**librarian never spawns a broad agent**, so that lever is already pulled.

Because AC1–AC3 target a cause that is absent, they are recorded here as
**already satisfied, with evidence**, rather than as work performed.

## Finding 2 — the shared prefix is a cache HIT, and already cheap

The headline "24.5k prefix" conflates two components that bill an order of
magnitude apart:

| component | what it is | billing |
| --- | --- | --- |
| `cache_read` | the shared system-prompt + tool-schema block, byte-identical across spawns | ~**0.1x** base (cache hit) |
| `cache_creation` | bytes unique to this spawn — dispatch prompt, diff, pre-scan handoff — **plus the shared block whenever the cache missed** | ~**1.25x** base |

Billing-weighted first turn (`split`):

| metric | value |
| --- | ---: |
| cached median | 11,359 |
| written median | 18,812 |
| median **weighted** first-turn tokens | 24,650 |
| cached share of weighted cost | **2.9%** |
| written share of weighted cost | **97.1%** |

**Consequence: ranking cuts by raw prefix size mis-ranks them.** #787's AC3 asks
to "rank removals by measured schema size". But schema bytes sit in the *cached*
component, which is 2.9% of what is actually billed. Shaving the shared block is
worth roughly a thirtieth of what its raw size suggests.

## Finding 3 — a 36% cache-MISS rate is the largest measured cost

Some spawns show `cache_read == 0` and a correspondingly larger
`cache_creation`: they **wrote** the shared block instead of reading it, paying
~12x for identical bytes.

| metric | value |
| --- | ---: |
| cache HIT | 22 (67%) |
| cache MISS | 11 (33%) |
| mean `cache_creation` on HIT | 17,316 |
| mean `cache_creation` on MISS | 29,951 |
| **implied shared block** | **12,635 tokens** |
| cost of shared block on HIT | 1,263 tok-equiv |
| cost of shared block on MISS | 15,794 tok-equiv |
| **miss penalty per spawn** | **14,530 tok-equiv (12x)** |

The per-spawn penalty is roughly **half a median prefix, paid for nothing** —
the bytes were already computed and cacheable. This is larger than any saving
reachable by editing agent frontmatter.

**Not fixed here.** The cause is harness/session-boundary behavior (candidate
hypotheses: the 5-minute prompt-cache TTL expiring between review cycles;
barrier scheduling in the fan-out; spawn ordering within a cycle), which is a
different root cause from agent-file size and would sprawl this change into
harness internals. Tracked as its own issue — see § Follow-up.

## Finding 4 — what the remaining lever actually is

With tool declarations already narrow and schemas mostly cached, the addressable
per-spawn bytes are the **agent body** — the prose sent on every dispatch.

| plugin | agent files | body lines |
| --- | ---: | ---: |
| review-audit | 10 | 2,479 |
| dev-core | 6 | 781 |
| workflow | 3 | 618 |
| **total** | **19** | **3,878** |

review-audit is 64% of it. The 8 audit scanners each carry a near-identical
~20-line "Batch Sub-Agent Dispatching" block (`audit-security.md:126`,
`audit-docs.md:96`, `audit-test-gaps.md:104`, `audit-code-health.md:128`, +4).

**But this is a voluntary saving, not a gate-forced one, and it was deliberately
not taken.** Every agent file is already **under** the `agent_md` budget
(warning 250 / high 400 in `check-decomposition/thresholds.yml`); `checker.md`
at 391 is the closest, and **no agent appears in `tests/prose-budget.baseline`**.
Extracting the shared block to a companion would move ~160 lines out of 8 files
— but each scanner would then have to *load* that companion, converting bytes
that are currently cached-and-nearly-free (Finding 2) into an on-demand read,
against a per-spawn cost that Finding 2 shows is already only 2.9% of billing.
The indirection is not obviously cheaper than the duplication it removes.
Recorded as a measured non-action rather than churning 8 agent files for a win
that the cost model does not support.

## AC disposition

| AC | Status |
| --- | --- |
| AC1 — every agent's `tools:` audited against observed use | **Satisfied** — all 19 audited (Finding 1); all already narrow |
| AC2 — each narrowing cites transcript evidence | **Vacuously satisfied** — no narrowing was warranted; the evidence *against* narrowing is transcript-derived (Finding 1's 29,288 median on a narrow list) |
| AC3 — schema sizes measured, removals ranked by saving | **Satisfied, and the premise corrected** — measured, and the ranking basis is wrong (Finding 2): schema bytes are cached at 2.9% of billed cost |
| AC4 — median prefix re-measured, delta recorded | **Satisfied** — re-measured (29,298 raw / 24,650 weighted). **Delta is nil by construction**, since no prefix-affecting change was made; the reproducible instrument is the deliverable |
| AC5 — no agent fails at runtime for a missing tool | **Satisfied** — no `tools:` declaration was changed, so no agent *can* newly fail. The adversarial review on this PR spawns `dev-core:code-reviewer` for real, exercising the spawn path |
| AC6 — `skill-required-tools-vocabulary` updated with per-spawn cost | **Redirected** — that file documents an unrelated contract (skill `metadata.yml` `required_tools[]`, *shell-command* names like `git`/`gh`, not Claude tool names). The measured cost went to `agent-authoring/SKILL.md` § Tool Scoping and `delegating-investigation/SKILL.md` § The break-even, which are the files that actually govern tool declarations |

## Limits

- **n=33, one machine, one day** — versus the issue's n=301 fleet figure. The
  *structural* findings (Finding 1) are repo facts and hold regardless of
  sample. The *cost* splits (Findings 2–3) are sampled; treat the percentages as
  this machine's, and the direction as robust.
- All observed spawns but one were `dev-core:code-reviewer`, because the local
  transcript corpus is dominated by ship-issue review cycles. The
  `general-purpose` figure is **n=1** and is indicative only.
- The cache hit/miss split is observed, not explained. Finding 3 states the cost,
  not the cause.

## Follow-up

- **Cache-miss investigation** —
  [#870](https://github.com/joshjhall/librarian/issues/870). Owns the *why*
  behind Finding 3 and any fix. It carries two distinguishable hypotheses (cache
  TTL expiring across CI waits vs. barrier scheduling racing to populate the
  cache), which is why the first step there is to timestamp misses against cycle
  boundaries rather than reason from the harness source.

## Reproducing

```bash
plugins/workflow/scripts/measure-spawn-prefix.sh summary
plugins/workflow/scripts/measure-spawn-prefix.sh split
plugins/workflow/scripts/measure-spawn-prefix.sh cache
```

Requires local subagent transcripts under `~/.claude/projects/` — run at least
one fan-out (a `/workflow:ship-issue` review cycle) first. With no python3 >=
3.11 the shim exits **77** with an actionable message rather than reporting
zeros.
