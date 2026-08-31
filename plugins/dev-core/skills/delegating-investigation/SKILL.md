---
description: When to delegate read-only investigation to a subagent instead of reading inline, with the measured break-even. Use when surveying many files, tracing a convention across a tree, or answering "where is X handled".
---

# Delegating Investigation

Read-only investigation — `grep`, `sed`, `cat`, `git log`, `gh view` — is the
single largest cost in a main session. Measured over 24h (#785): **49% of
main-session Bash calls, producing 67% of all tool-result tokens.** Bash results
carry **76% of all re-read debt** (138.9M of 182.6M), because a result does not
cost once — it is re-sent with every subsequent request for the rest of the
session.

Delegating that work to a subagent saves twice. It reprices the tokens, and —
the larger half — the exploration **never enters the parent context at all**.
Only the conclusion does.

**But delegation is not free, so it is not always right.** This skill is the
arithmetic for deciding, and the guard against the failure mode that arithmetic
prevents: delegating a one-line lookup, which is strictly slower and more
expensive than just reading the file.

## The break-even

Both numbers are **measured in this repo**. Cite them; do not re-derive them.

| | tokens | source |
| --- | ---: | --- |
| Cost **to** delegate — median spawn prefix, **billing-weighted** | **~24,650** | #787, n=33 spawns |
| Cost **to** delegate — median spawn prefix, **raw** | 29,298 | #787 (p90 30,762); earlier fleet figure 24,568, n=301 |
| Cost **not to** — the investigation's own result volume **plus its re-read debt** | varies | #785 |

```text
delegate when:  result_tokens x turns_resident  >  ~24,650
```

**Use the billing-weighted figure, not the raw one** (#787;
`docs/verification/subagent-prefix-e2e-787.md`). A spawn's first turn splits into
a shared system-prompt + tool-schema block that is byte-identical across spawns —
normally a **cache hit** at ~0.1x — and per-spawn bytes written at ~1.25x. The
cached half is only ~3% of what is actually billed, so the raw prefix
**overstates** the true cost of delegating. The two numbers landing so close
together is a coincidence of this sample, not an identity: the raw median rose
while the weighted one held.

One caveat that cuts the other way: ~1 spawn in 3 **misses** that cache and pays
~12x for the same bytes, which is a ~14.5k penalty on top. So the break-even is
genuinely noisy per-spawn. Treat ~24.6k as the expected cost and do not
delegate anything close to the line.

The multiplier is the part that is easy to forget and is usually decisive. A
40k-token survey result is not a 40k cost — sitting in context for 30 more
turns, it is the dominant line item in the session. That product, not the raw
result size, is what clears the prefix.

So the question is never "would a subagent be tidier" — it is whether this
particular investigation's result, times how long it stays resident, is bigger
than ~24.6k.

## Delegate — fan-out reading

The win is on **breadth**, where the reading is wide and the answer is narrow:

- Surveying many files or a whole directory tree
- Tracing a convention or pattern across the repo ("how do the other skills
  do X")
- "Where is X handled?" / "what calls this?" when the location is unknown
- Any investigation you would open with a broad `grep -r` over the repo root
- Anything you expect to take more than a handful of tool calls to answer

These clear the break-even easily and have the best shape for it: a large,
disposable exploration collapsing to a short conclusion.

## Do NOT delegate — targeted reading

**A targeted read is cheaper inline, always.** Below the break-even, delegation
makes the agent slower *and* costs more:

- Reading a known file, or a known line range (`sed -n '40,60p' file.sh`)
- Checking one function whose location you already know
- A single `git log` / `git show` on one path
- Anything whose answer is one `grep` you can already write
- Following up on something a previous subagent already reported

Over-delegation is a real failure mode, not a theoretical one: a one-line lookup
routed through a subagent pays 24.5k to save a few hundred tokens, and adds a
round-trip of latency. When an investigation is genuinely borderline, read it
inline — the inline cost is bounded and visible, while a spawn is a fixed
up-front loss.

## Dispatch it at the sonnet tier

**Delegating to opus forfeits half the saving.** The repricing half only happens
if the subagent runs on a cheaper tier: measured on the same fleet window,
opus-5 costs **1.93x** sonnet-5 per token here (not 5x — `cache_read` dominates,
and its ratio is 0.5 vs 0.3). An opus subagent still keeps the exploration out of
the parent context, but pays parent-tier rates to do it.

Investigation is the shape sonnet handles well: the reading is wide but each
step is mechanical, and the judgment is concentrated in the short conclusion.

- **Subagent dispatch** — `Explore` (read-only, purpose-built for this) or
  `general-purpose`.
- **Inside a `workflow.js` harness** — pass `model: 'sonnet'` alongside
  `agentType` on the `agent()` call.

Reserve opus for stages where a wrong call compounds — an adversarial judge, a
final gate — not for reading files. That is the same rule the review and audit
harnesses already apply when they pin **only** their judge/verify stages to opus.

## Conclusions, not transcripts

**This is the half of the saving that repricing does not deliver, and it is lost
if the subagent dumps what it read.**

A delegated investigation must return:

- The answer, stated directly
- `file:line` anchors for anything the parent will act on
- What it ruled out, when that is load-bearing

It must NOT return: file contents, command output, a log of what it searched, or
"here is everything I found" followed by the raw material. If the parent ends up
holding the exploration anyway, the delegation bought nothing but a spawn prefix.

Say so in the dispatch prompt. An agent asked to "investigate X" will often
narrate; an agent asked to "return the answer and the file:line anchors, not
what you read" will not.

## The `SCOPE_DISCIPLINE` boundary — do not harmonize these

The review harness (`ship-issue/workflow.js`) tells its reviewers the **opposite
thing**: stop exploring, stay anchored to the diff, budget ~10 tool calls. That
is deliberate and it worked — per-reviewer Bash calls fell 31.5 → 2.2.

These two rules are not in conflict, because **they govern different agents**:

- `SCOPE_DISCIPLINE` bounds a **reviewer**, which already has the diff it needs
  and whose exploration is mostly re-derivation.
- This skill governs the **parent session's** investigation, where the reading
  is genuinely necessary and the only question is who does it.

Do not weaken `SCOPE_DISCIPLINE` in the name of delegation, and do not paste
delegation guidance into a reviewer prompt. A reviewer that starts dispatching
investigation subagents has reintroduced the unbounded exploration that
`SCOPE_DISCIPLINE` exists to stop, at a 24.5k premium per spawn.

## When to Use

- A planning or audit phase that opens with broad code exploration
- Any point where you are about to run several wide `grep`/`find` calls
- Deciding whether a piece of reading is worth a subagent

## When NOT to Use

- Inside a review harness reviewer — see the boundary above
- When you already know the file and line
- When the answer is one command you can write now
