---
name: classify-tool-calls-before-optimizing
description: "Before optimizing an agent's token cost, classify its actual tool calls — twice now my predicted hot spot was under 10% of the real burn"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b03da476-855a-4340-a1de-499a566aea26
  modified: 2026-07-28T20:46:52.923Z
---

When attacking an LLM agent's token cost, **classify its actual tool calls from
the transcript before choosing a fix**. Aggregate token counts tell you *which
agent* is expensive; only the call-level breakdown tells you *why*, and the two
have diverged every time I have checked.

Two misses in one session (2026-07-28, the #553/#556/#557 chain):

1. I ranked #492 re-review narrowing as the top lever, on the theory that
   cycles 2-3 were silent full re-reviews at 3× cost. Measurement: narrowing
   never engaged at all, and cycle 2 cost 2.7× cycle 1 on the *same 2-file
   diff*. Cost tracked in-agent exploration, not diff size.
2. I proposed a "conventions rule table" to stop five reviewers each re-reading
   CLAUDE.md. Classifying `conventions`'s 207 Bash calls across three cycles:
   **164 were `awk`/`grep`/`find` hand-measurement**, 19 were doc reads, 6 were
   lint reruns. My fix targeted under 10% of the burn.

The recipe that worked:

```sh
# per-agent totals — MUST dedup by message.id (see [[token-scrape-transcript-dedup]])
jq -rn --slurpfile r "$f" '[$r[]|select(.message.usage!=null)
  |{id:.message.id,u:.message.usage}]|unique_by(.id)
  |{turns:length, out:([.[].u.output_tokens//0]|add),
    cr:([.[].u.cache_read_input_tokens//0]|add)}'

# what it actually RAN — this is the part that changes the fix
jq -r 'select(.type=="assistant")|.message.content[]?
  |select(.type=="tool_use" and .name=="Bash")|.input.command' "$f"
```

Then bucket the commands. Identify agents by reading `Mode:` from the head of
their transcript rather than guessing from cost rank — rank is unstable
([[review-cost-baseline-2026-07-28]] has `security` ranging 13→128 turns across
three cycles of nearly the same change).

**Why it matters:** an agent that hand-rolls six `awk` variants to count long
lines is not "exploring too much" — it is recomputing what a linter already
computes. That diagnosis points at feeding tool output in as data; the
"exploring too much" diagnosis points at prompt limits. Same symptom, different
fix, and only the call log distinguishes them.

Related: [[review-cost-baseline-2026-07-28]], [[issue-553-review-token-ceiling]],
[[token-scrape-transcript-dedup]], [[token-burn-audit-2026-07-21]]
