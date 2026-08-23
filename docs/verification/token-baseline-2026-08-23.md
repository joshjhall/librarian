# Fleet token baseline — frozen reference window (#781)

**Status: FROZEN.** This is the first reference window for the token-efficiency
series (#782–#788). Every downstream change is measured as a delta against it.

Completed-report shape rather than a running tally: the window is closed and the
numbers do not change (per CLAUDE.md § `docs/verification/`).

## The window

```text
2026-08-22T18:00:00Z .. 2026-08-23T18:00:00Z
```

Reconciled: **28,702** per-model requests against **28,702** unfiltered (delta 0,
tolerance 144 at the default 0.5%).

| model | requests | prompt tokens | completion tokens | cost | avg prompt/req |
| --- | ---: | ---: | ---: | ---: | ---: |
| claude-opus-5 | 12,038 | 2,987,111,272 | 5,047,062 | $2,081.56 | 248,140 |
| claude-sonnet-5 | 16,663 | 1,368,127,964 | 5,784,191 | $496.69 | 82,105 |
| text-embedding-3-small | 1 | 4 | 0 | $0.00 | 4 |
| **total** | **28,702** | **4,355,239,240** | **10,831,253** | **$2,578.25** | **151,739** |

**The headline number is 151,739 average prompt tokens per request.** Judge every
change in #782–#788 on that, not on total cost: cost moves with how hard the
fleet is pushed, while the average isolates an efficiency change from a workload
change.

The shape that motivates the series is intact here: prompt tokens are
**4.355B of 4.366B (99.75%)**; completion tokens are 10.8M (0.25%). Average
output is 377 tokens per request against 151,739 in. The fleet is not paying to
generate — it is paying to re-send context ~29k times a day.

## Regenerating

```bash
export BIFROST_URL=https://bifrost.example        # gateway ADMIN root
plugins/workflow/scripts/token-report.sh window \
  --start 2026-08-22T18:00:00Z --end 2026-08-23T18:00:00Z
```

To measure a change, capture a fresh window and diff:

```bash
plugins/workflow/scripts/token-report.sh window --start … --end … > after.tsv
plugins/workflow/scripts/token-report.sh compare \
  --baseline docs/verification/token-baseline-2026-08-23.tsv --compare after.tsv
```

The rows above are exactly what `window` prints (thousands separators and the
`$` added for reading); the run is reproducible — two consecutive invocations
returned identical figures.

## Worked example — why the metric choice matters

`compare` against the preceding 24h window (2026-08-21T18:00Z .. 2026-08-22T18:00Z),
run live:

```text
model                              requests  prompt_tokens         cost    avg/req
claude-opus-5                         +3138    +1313658529      +834.35     +60112
                                     +35.3%         +78.5%       +66.9%     +32.0%
claude-sonnet-5                       +4559     +537135014      +178.58     +13451
                                     +37.7%         +64.6%       +56.1%     +19.6%
TOTAL                                 +7697    +1850793543     +1012.93     +32508
                                     +36.6%         +73.9%       +64.7%     +27.3%
```

Read cost alone and this is a **+64.7%** day. But requests rose **+36.6%** over
the same span, so most of that is workload, not waste — while `avg/req` still
rose **+27.3%**, which is a real efficiency regression underneath the growth.
Total cost conflates the two; the average separates them. That is the whole
argument for judging #782–#788 on `avg/req`.

## Discrepancy against the issue body — read this before comparing

Issue #781's problem statement carries a table from the original 2026-08-23
ad-hoc measurement. **It does not reproduce.** Re-querying that same window with
this tool returns figures ~2% lower across the board:

| | issue body | this tool | delta |
| --- | ---: | ---: | ---: |
| opus-5 requests | 12,337 | 12,038 | −299 (−2.4%) |
| opus-5 tokens | 3.06B | 2.99B | −2.3% |
| opus-5 cost | $2,143 | $2,081.56 | −2.9% |
| sonnet-5 requests | 16,999 | 16,663 | −336 (−2.0%) |
| sonnet-5 tokens | 1.40B | 1.37B | −2.3% |
| sonnet-5 cost | $509 | $496.69 | −2.4% |
| total cost | $2,648 | $2,578.25 | −2.6% |
| avg prompt/req | 151,775 | 151,739 | −36 (−0.02%) |

**The tool's numbers are the frozen baseline** — a baseline the tool cannot
reproduce would hand #782–#788 a phantom ~2% improvement before they changed
anything, which is precisely the class of error #781 exists to eliminate.

Cause not established; candidates are a slightly different window boundary in
the original ad-hoc query, or retention/backfill settling between the two reads
(the gateway reports `log_retention_days: 365`, so wholesale expiry is not it).
Worth noting the **average prompt per request agrees to 0.02%** — the headline
metric is stable even though the absolute counts are not, which is consistent
with a window-boundary difference sampling slightly fewer requests of the same
character. Investigating the ~2% is out of scope here; file a follow-up if a
root cause is ever needed.

## Gateway facts worth keeping

Established by live probing during implementation. Each shaped the tool:

| Fact | Why it matters |
| --- | --- |
| `/api/logs/stats` answers in ~16 ms; `/api/logs` needs ~52 s per 500-row page (~50 min/day). | The aggregate endpoint is the only viable basis; the tool never paginates. |
| `?models=` filters. `?model=` is **silently ignored** and returns the unfiltered total with HTTP 200 — measured 89,027 vs 359,642. | The reconciliation guard exists for this. A typo returns a wrong number that reads as right. |
| `?zzznotaparam=1` also returns the unfiltered total. | The failure class is *any* dropped or renamed param, not just the one typo. |
| `/api/models` returns 5 of 14 models without `?limit`, while its own `total` field says 14. | Enumeration passes a limit and asserts `returned == total`; a short list would drop models from the sum and manufacture a breach. |
| `ANTHROPIC_BASE_URL` is the **proxy** path (`…/anthropic`); `/api/logs/stats` under it returns the web UI's HTML with HTTP 200. | `BIFROST_URL` is separate and required; it must point at the gateway root. |
| A dead host yields curl exit 7 / HTTP `000`. | Cleanly separates unreachable (77) from misconfigured (2) and wrong-data (1). |

## Provenance

Generated by `plugins/workflow/scripts/token-report.sh` on 2026-08-23 against the
live gateway. The `models=`→`model=` mutation was verified against that same live
gateway: the mutant summed 401,828 requests against an actual 28,702 and exited 1
with the reconciliation failure, so the guard is proven on real data and not only
against the test stub.
