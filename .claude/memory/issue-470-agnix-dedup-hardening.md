---
name: issue-470-agnix-dedup-hardening
description: "#470 SHIPPED PR #546 (L3): agnix rule_severity→certainty passthrough sent every agnix row down the HIGH auto-include fast path skipping LLM confirmation; review found a live TSV injection the new severity prefix made load-bearing"
metadata: 
  node_type: memory
  type: project
  originSessionId: 084c5ffe-88b5-4eb0-aaec-eec0a1c096c6
  modified: 2026-07-28T05:14:44.783Z
---

**#470** (severity/medium, effort/medium) — three deferred adversarial-review
findings from #401/PR #469 on the Step 6 agnix precedence-dedup. Shipped as
PR #546 at L3 on 2026-07-27.

**A filed follow-up's findings are not all still live — check before scoping.**
Finding #2 ("Step 6 keys on exact `file:line`") was **already fixed** by #402 /
PR #477, which re-keyed Step 6 to *per underlying issue*. Only its
*interaction* with the within-skill merge survived. Scoping to the filed text
would have produced a no-op change to a key that no longer existed. See
[[issue-402-precedence-dedup]].

**The load-bearing defect was a tier conflation, not the dedup itself.** Both
normalizer impls emitted agnix's `rule_severity` verbatim into the TSV
`certainty` column. `rule_severity` is issue *severity*, not detection
*confidence*, and agnix marks nearly its whole `CC-*` surface HIGH — so
essentially every agnix row took `checker.md`'s **`certainty=HIGH`
auto-include fast path** and reached the report with **no Pass-2 LLM
confirmation**. Fix = flat `MEDIUM` (the established "needs confirmation" tier,
as `check-lifecycle` uses), severity moved into the evidence prefix
`[<RULE-ID>|<SEVERITY>] <message>`.

**Reusable bug class — a new structured prefix over untrusted text creates a
parsing attack surface.** The pre-PR review found (and I reproduced) that agnix
`message` text quotes matched source lines from the *audited* repo, so an
embedded tab forged extra TSV **columns** (10 vs 5) and a newline forged an
entire extra **row**. Pre-existing, but Guard 2 now *reads that prefix to
decide a drop*, so it became load-bearing. Two distinct defenses were needed:

1. **Structural** — scrub `\t`/`\n`/`\r` at the emit choke point (both impls).
2. **Positional** — the delimiters `[`/`|`/`]` are deliberately **NOT** escaped
   (ordinary chars in quoted source; escaping corrupts human-readable
   evidence). The guarantee is that the real tag sits at **index 0**, so the
   consuming prose must say "anchor the parse at index 0, later bracket groups
   are inert." An implicit invariant is not an enforced one when the consumer
   is LLM-followed prose.

**A test's line bound may be a mis-anchor detector, not a prose budget.**
`validate-agnix-checker-wiring.sh`'s `assert_wired` hardcoded `<= 90` — sized
for Step 3a, but applied to Step 6 too. Step 6 legitimately grew past it.
Correct fix = parameterize (`STEP6_MAX_LINES=110`), not cut operative content.
Read *why* a bound exists before trimming to satisfy it.

**Not every listed file needs changing.** The plan listed
`tests/coverage-python.sh`; its agnix fixtures feed `>/dev/null` with no golden
assertions, so they are coverage inputs only — verified unnecessary rather than
edited to match the plan.

Both new test families were **revert-verified** to fail without the fix
([[issue-392-token-signal-coverage]]'s tautology lesson).
`checker.md` hit 631 lines (over `AGENT_HIGH=400`) — recorded on #503 rather
than extracted here, since that would move the prose under review out from
under its own assertions. See [[issue-503-large-file-decompose]].
