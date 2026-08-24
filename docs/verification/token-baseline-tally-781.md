# Fleet token baseline — reference window (#781)

**Status: OPEN — the first reference window.** Every token-efficiency change in
the #782–#788 series is measured as a delta against the ratios below. Later
windows get appended here as they are captured, so this is a running tally
rather than a completed report (per CLAUDE.md § `docs/verification/`).

**Figures are NORMALIZED, deliberately — see § Why no absolute figures.**

## The window

```text
2026-08-22T18:00:00Z .. 2026-08-23T18:00:00Z   (24h)
```

Reconciled exactly: per-model request counts summed to the unfiltered total,
delta 0, against a 0.5% tolerance.

| model | share of requests | share of cost | avg prompt/req | avg output/req | relative $/Mtok |
| --- | ---: | ---: | ---: | ---: | ---: |
| claude-opus-5 | 41.9% | 80.7% | 248,140 | 419 | 1.92× |
| claude-sonnet-5 | 58.1% | 19.3% | 82,105 | 347 | 1.00× |
| **fleet** | **100%** | **100%** | **151,739** | **377** | **1.63×** |

**The headline number is 151,739 average prompt tokens per request.** Judge every
change in #782–#788 on that, not on cost: cost moves with how hard the fleet is
pushed, while the average isolates an efficiency change from a workload change.

The shape that motivates the whole series: **prompt tokens are 99.75% of all
tokens; completion tokens are 0.25%.** Average output is 377 tokens per request
against 151,739 in — a ratio of roughly **1:400**. The fleet is not paying to
generate; it is paying to re-send context on every request.

The second finding is the model split: opus-5 serves **41.9% of requests** but
carries **80.7% of cost**, at **1.92×** sonnet-5's cost per token. That gap is
what #785 (delegate read-only investigation to sonnet) exists to exploit.

## Why no absolute figures

This repo is **public**. Committing exact fleet-wide request counts and dollar
totals would publish this org's LLM spend, model mix, and daily volume
permanently — readable by anyone, surviving any later deletion, in a repo that
can be forked or mirrored.

Nothing in the series needs them. #782–#788 are judged on `avg_prompt_per_request`
and on percentage deltas, all of which are preserved above at full precision. A
ratio is exactly as good a before/after anchor as an absolute and discloses
nothing, so the normalized form is strictly better here.

**Absolute figures stay reproducible on demand** — `token-report.sh` prints them
from the live gateway for anyone with `BIFROST_URL` and access. They are simply
not committed. To re-derive this table:

```bash
export BIFROST_URL=https://bifrost.example        # gateway ADMIN root
plugins/workflow/scripts/token-report.sh window \
  --start 2026-08-22T18:00:00Z --end 2026-08-23T18:00:00Z
```

**No baseline `.tsv` is committed**, for the same reason. `compare` diffs
absolute token and cost fields, so a normalized TSV would yield meaningless
deltas, and a faithful one would commit exactly the figures this section
withholds. Since the window is fixed and the gateway reproduces it on demand,
regenerate **both** sides at compare time instead:

```bash
TR=plugins/workflow/scripts/token-report.sh
"$TR" window --start 2026-08-22T18:00:00Z --end 2026-08-23T18:00:00Z > /tmp/baseline.tsv
"$TR" window --start <new-window-start>    --end <new-window-end>    > /tmp/after.tsv
"$TR" compare --baseline /tmp/baseline.tsv --compare /tmp/after.tsv
```

**Default `compare` output is NOT safe to paste.** Each model gets two lines:
absolute deltas first, percentages beneath — and the absolute line carries raw
request counts, token volumes and a dollar delta. Use `--percent-only` for
anything published:

```bash
"$TR" compare --baseline /tmp/baseline.tsv --compare /tmp/after.tsv --percent-only
```

That prints one percentage row per model and nothing else, which is what the
series is judged on anyway. The intermediate `.tsv` files carry full absolutes
and stay in `/tmp`; never commit them.

## Worked example — why the metric choice matters

`compare` against the preceding 24h window (2026-08-21T18:00Z .. 2026-08-22T18:00Z),
run live, percentages only:

```text
model                              requests  prompt_tokens         cost    avg/req
claude-opus-5                        +35.3%         +78.5%       +66.9%     +32.0%
claude-sonnet-5                      +37.7%         +64.6%       +56.1%     +19.6%
TOTAL                                +36.6%         +73.9%       +64.7%     +27.3%
```

Read cost alone and this is a **+64.7%** day. But requests rose **+36.6%** over
the same span, so most of that is workload, not waste — while `avg/req` still
rose **+27.3%**, a real efficiency regression underneath the growth. Total cost
conflates the two; the average separates them. That is the whole argument for
judging the series on `avg/req`.

## Discrepancy against the issue body — read this before comparing

Issue #781's problem statement carries a table from the original 2026-08-23
ad-hoc measurement. **It does not reproduce.** Re-querying that same window with
this tool returns figures ~2% lower across the board — request counts ~2.0–2.4%
low, token volumes ~2.3% low, cost ~2.6% low.

**The tool's numbers are authoritative here.** A baseline the tool cannot
reproduce would hand #782–#788 a phantom ~2% improvement before they changed
anything, which is precisely the class of error #781 exists to eliminate.

Cause not established; candidates are a slightly different window boundary in
the original ad-hoc query, or retention/backfill settling between the two reads
(the gateway reports `log_retention_days: 365`, so wholesale expiry is not it).
Worth noting the **average prompt per request agrees to 0.02%** (the issue's
151,775 against 151,739) — the headline metric is stable even though the absolute
counts are not, which is consistent with a window-boundary difference sampling
slightly fewer requests of the same character. Investigating the ~2% is out of
scope here; file a follow-up if a root cause is ever needed.

## Gateway facts worth keeping

Established by live probing during implementation. Each shaped the tool:

| Fact | Why it matters |
| --- | --- |
| `/api/logs/stats` answers in ~16 ms; `/api/logs` needs ~52 s per 500-row page (~50 min/day). | The aggregate endpoint is the only viable basis; the tool never paginates. |
| `?models=` filters. `?model=` is **silently ignored** and returns the unfiltered total with HTTP 200 — measured at a **4.0× overstatement** on a single-model query. | The reconciliation guard exists for this. A typo returns a wrong number that reads as right. |
| `?zzznotaparam=1` also returns the unfiltered total. | The failure class is *any* dropped or renamed param, not just the one typo. |
| `/api/models` returns 5 of 14 models without `?limit`, while its own `total` field says 14. | Enumeration passes a limit and asserts `returned == total`; a short list would drop models from the sum and manufacture a breach. |
| `ANTHROPIC_BASE_URL` is the **proxy** path (`…/anthropic`); `/api/logs/stats` under it returns the web UI's HTML with HTTP 200. | `BIFROST_URL` is separate and required; it must point at the gateway root. |
| A dead host yields curl exit 7 / HTTP `000`. | Cleanly separates unreachable (77) from misconfigured (2) and wrong-data (1). |

## Provenance

Generated by `plugins/workflow/scripts/token-report.sh` on 2026-08-23 against the
live gateway, then normalized to ratios for publication. The `models=`→`model=`
mutation was verified against that same live gateway: the mutant's per-model sum
overstated the true request count by **14×**, tripping the reconciliation guard
and exiting 1. The guard is therefore proven on real data, not only against the
test stub.
