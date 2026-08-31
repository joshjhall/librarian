---
name: measured-cause-may-invert-the-remedy
description: An issue's remedy can be aimed at the cheap half of the cost; measure the SPLIT before acting on the total
metadata:
  type: feedback
---

A perf issue quoting a big total ("24.5k prefix, 53% of input") can still
prescribe the wrong fix, because a total hides a **billing split**. #787 asked to
narrow `tools:` declarations; measuring showed tool schemas sit in the
*cache-read* half (~0.1x, ~3% of billed cost) while ~97% was per-spawn *writes*
(~1.25x). Ranking cuts by raw size ranks them by the nearly-free component.

**Why:** this is a stronger failure than [[issue-cause-may-be-falsified-by-measurement]].
There the suggested fix was a no-op; here the fix was *plausible and directionally
backwards* — every premise ("agents declare broad tools") was checkable in ten
seconds and all were false (19 agents not 38; zero `Tools: *`; no MCP). Nobody
checked because the headline number was real.

**How to apply:** before implementing a cost fix, (1) verify the premise's
*countable* claims first — file counts, declarations, config presence — they are
cheap and they falsify fastest; (2) decompose the metric into what is billed
differently (cached vs written, hit vs miss), not just what is large; (3) if the
remedy is falsified, say so in the issue and re-aim, rather than performing the
prescribed motions for AC-completion. A deliberate **non-action, measured and
recorded**, is a legitimate deliverable — see [[surviving-mutation-may-be-a-real-no-op]].

Corollary found the same way: the biggest lever is often *not in the issue at
all*. A 33% cache-MISS rate paying 12x for identical bytes dwarfed everything the
issue proposed, and became its own issue rather than scope creep.
