---
name: review-cost-after-2026-07-28
description: "AFTER measurement for #559 — review harness cost/recall once #553/#556/#557 shipped in v0.8.2; cost fell ~6-20x, recall unproven at n=2"
metadata: 
  node_type: memory
  type: project
  originSessionId: ea401363-2ee0-40ee-95f3-eac14055d50b
  modified: 2026-07-29T03:02:27.376Z
---

The "after" arm for [[review-cost-baseline-2026-07-28]], answering #559. Written
2026-07-28. The baseline numbers are frozen; these are the post-v0.8.2 numbers
measured against them.

**Headline: cost fell hard and the #557 targets were all hit. Recall is NOT
proven — only two post-change cycles exist, and the fuller of the two returned
zero findings, which n=2 cannot separate from "the reviewers stopped looking."**

## The before/after cut is in UTC — this is easy to get wrong

Transcript directory mtimes are **local** (`-0500`); PR merge times from `gh`
are **UTC**. v0.8.2 landed 2026-07-28: #554 at 20:33Z, #558 at 20:58Z, #560
(release) at 21:07Z. Comparing a local mtime against a UTC merge time
misclassifies a 5-hour band of runs. `wf_fd97ac60` looks like 17:54 locally and
is actually **22:54Z — after the cut**. Always
`TZ=UTC stat -c %y <dir>` before assigning a run to an arm.

| workflow | UTC | PR | arm | agents | output | cache_read |
| --- | --- | --- | --- | --- | --- | --- |
| wf_2f959e43 | 07-27 20:53 | #539 | before | 7 | 192k | 11.5M |
| wf_26393217 | 07-27 21:05 | #539 | before | 7 | 82k | 5.2M |
| wf_8edbc5ae | 07-28 00:20 | #540 | before | 8 | 208k | 5.6M |
| wf_8d93c4b3 | 07-28 04:29 | #477 | before | 7 | 294k | 15.9M |
| wf_ca1f27a4 | 07-28 05:03 | #477 | before | 7 | 274k | 7.2M |
| wf_9fb83752 | 07-28 16:53 | #547 | before (baseline c1) | 7 | 173k | 6.2M |
| wf_02c311e6 | 07-28 17:32 | #547 | before (baseline c2) | 7 | 281k | 16.9M |
| wf_5300fbc5 | 07-28 18:13 | #547 | before (baseline c3) | 7 | 207k | 9.0M |
| **wf_fd97ac60** | **07-28 22:54** | **#561** | **AFTER (partial)** | 7 | **34k** | **885k** |
| **wf_32c23d63** | **07-29 02:27** | **#565/#566** | **AFTER (full)** | 6 | **9k** | **443k** |

## The two after-runs are NOT the same experiment

Issue #559 warns that a `none supplied` handoff means the run is a re-run of
the baseline, not a test. Checking that log line is what separates these:

- **`wf_fd97ac60` (PR #561) — partial.** Logs `pre-scan: none supplied` and
  `conventions digest: none`. Its reviewer prompts *do* carry the
  `PROJECT CONVENTIONS` markers, but the body between them is **empty** — the
  scaffolding shipped, the payload did not. This run tests #557's
  **scope-discipline prose only**.
- **`wf_32c23d63` (PR #565/#566) — full.** Logs
  `pre-scan: 2 candidate(s) supplied` and `conventions digest: 1647 chars`, with
  a real digest body (the workflow.js-sandbox rules, the bash-3.2 floor, the
  scope enum). This is the **only** full test of #556 + #557 on disk.

That the *partial* run already dropped to 34k output is itself informative: most
of the win comes from the scope-discipline prose, not from the payloads.

## Q1 — did the hand-measurement stop? Yes, decisively

Per-reviewer averages across 41 before-reviewers vs 10 after-agents (`manifest`
and `judge` excluded from the reviewer averages):

| metric | before (per reviewer) | after (per reviewer) |
| --- | --- | --- |
| Bash calls | 31.5 | 2.2 |
| `awk`/`grep`/`find`/`wc`/`sed` | 22.1 | 2.2 |
| lint reruns (rumdl/shellcheck/typos/ruff) | 53 total | **0** |
| CLAUDE.md / AGENTS.md / memory reads | 38 total | **0** |
| `Grep` tool calls | 0 | 0 |

The `conventions` dimension — #557's named target, 20-49 hand-measure calls in
every before-run — drops to **5** (partial) and **1** (full). All three #557
checkboxes are answered yes: hand-measurement fell, no reviewer re-ran a lint
tool, no reviewer re-read the convention files.

**The one thing #557 did not fix: reviewers still make zero `Grep` calls, in
both arms.** They explore by shelling out or not at all. "Prefer reading a
changed file over grepping the repo" was followed by dropping the exploration,
not by switching tools.

## Q2 — did total cost fall? Yes, ~6-20x

Per-cycle output: baseline **173k / 281k / 207k** → **34k** and **9k**.
Per-cycle cache_read: baseline **6.2M / 16.9M / 9.0M** → **885k** and **443k**.

The mechanism is the one the baseline predicted: cache_read tracks Bash calls at
~50-80k each, so collapsing Bash collapses cache_read. `security` went 115 → 0
Bash calls; `conventions` 63 → 1. Nothing about the diff sizes explains it —
the after-runs' diffs (2 files each) are the same size as baseline cycles 1-2.

## Q3 — did recall hold? UNPROVEN — this is the honest gap

Findings per run: before **5 / 4 / 3 / 10 / 5 / 5 / 1 / 4** → after **3**
(partial) and **0** (full).

- **Cycles-to-clean did NOT increase.** Both after-runs went clean in one
  cycle, against a 3-cycle baseline. #559 calls this the single most important
  number, and it is satisfied on n=2.
- **But 0 findings is ambiguous.** On a 2-file diff it is equally consistent
  with "clean diff" and "reviewers spent 2.2 tool calls and stopped." The ~10
  call budget is being followed; whether it is sufficient is not observable from
  a run that found nothing.
- The pre-scan-candidate sub-questions (was a false positive wrongly confirmed?
  did a pre-scan row anchor a reviewer away from a real finding?) are
  **unanswerable at n=1** — `wf_32c23d63` is the only run that received
  candidates, and it confirmed none of them and found nothing else. That is the
  correct behavior for 2 candidates the reviewers judged spurious, but one
  sample cannot distinguish correct dismissal from blanket dismissal.

Do not record this as "recall held." Record it as "recall did not visibly break,
on two cycles, one of which found nothing."

## Q4 — is a token ceiling sizeable? No. Keep it OFF

Two `output_tokens` samples — **34,595** and **9,287** — plus three baseline
cycles is not a distribution, and the two after-samples already differ by 3.7x
on comparable diffs. There is no p95 here, only a range.

The ceiling shipped off for a concrete reason (a value below actual output
truncates every cycle, forces `clean: false`, drives `cycle++` to the cap, and
dead-ends the PR). Nothing in this data justifies turning it on. Revisit after
~10 more cycles of `token_report`.

## Q5 — what is the next lever?

- **Cost-ranking instability** (baseline: `security` 13 → 128 turns) is
  unmeasurable at n=2. The caution stands: do not demote a dimension on one
  run's ranking. #551 is still un-evidenced.
- **#550 and #551 are now hard to justify.** At 9-34k output per cycle the
  fan-out is no longer the expensive part of a ship. Routing small diffs around
  it optimizes something that now costs little.
- **The next lever is data collection, not another prompt change.** Keep
  `token_report` on and accumulate cycles until Q3 and Q4 can be answered.

## Verdict per change

- **#557 (lint authoritative + conventions digest + scope discipline) — paid
  off, clearly.** It is responsible for essentially all of the measured drop;
  the partial run proves the prose alone does most of the work.
- **#556 (pre-scan candidates to reviewers) — untested at scale.** Exactly one
  run received candidates. No evidence for or against.
- **#553 (token_report instrument) — paid off as an instrument.** It made this
  measurement possible without transcript archaeology. Its ceiling stays off.
- **The honest caveat from those PRs still stands:** all three are prompt
  guidance, not enforcement — `agent()` exposes no turn cap. Guidance was
  *sufficient* here, on two cycles, with no adversarial pressure on it.

## Method notes (reproduce before trusting)

- **Dedup by `message.id`** or figures run ~2x high — see
  [[token-scrape-transcript-dedup]].
- **Count Bash calls with `jq` array length, never `wc -l`.** Multi-line
  commands inflate a `wc -l` count by roughly 1.5x. This bit me mid-analysis.
- **Findings live in the `StructuredOutput` tool input**
  (`.input.findings`), not in the agent's final text message. Counting
  `"severity"` keys in the last text block returns 0 for every run.
- Classify tool calls rather than trusting aggregate tokens — see
  [[classify-tool-calls-before-optimizing]].

```sh
B=~/.claude/projects/-workspace-librarian
for d in $B/*/subagents/workflows/wf_*/; do
  echo "$(TZ=UTC stat -c %y "$d" | cut -c1-16)Z $(basename "$d")"
  for f in "$d"agent-*.jsonl; do
    jq -rn --slurpfile r "$f" '
      ($r | map(select(.type == "assistant"))
         | [.[].message.content[]? | select(.type == "tool_use")]) as $t
      | ($t | map(select(.name == "Bash") | .input.command)) as $b
      | "bash=\($b | length) meas=\([$b[] | select(test("\\b(awk|grep|find|wc|sed)\\b"))] | length)"'
  done
done
```
