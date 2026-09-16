---
name: one-time-cost-vs-per-request-surcharge
description: A big one-time cost looks worse than a small recurring one until you multiply; compare them at a break-even count, and say what makes the count large
type: feedback
metadata:
  node_type: memory
---

When a design weighs "pay a large cost once" against "keep paying a small
surcharge", the one-time number is the one that feels decisive and the recurring
one is the one that usually wins. State the **break-even count**, not the two
costs — `one_time / per_request_delta` — and then say how many units the real
workload actually spends past that point.

Worked (#1056, context-budget handoff): a handoff costs ~161k weighted units
**once**; a request carrying 175-200k of context costs ~8-11k units **more** than
the same request at the floor. Break-even ~15-20 requests; the sessions that
reach the threshold spend 38-92 requests in that band, crossing it 2-5x over. The
objection "but reloading the base context is expensive" is *true about the
magnitude* and still reaches the wrong conclusion, because it compares a one-time
figure against a per-request one.

**Why:** the intuition is not innumeracy — the one-time cost is genuinely large
and genuinely visible, while the surcharge is invisible precisely because it is
spread. Answering with a verdict ("the sweep says 175k") does not move anyone;
answering with the break-even does, because it is the quantity the intuition was
missing.

**How to apply:** when someone challenges a cost tradeoff, do not re-assert the
model's output. Price both sides in one unit, divide, and report the break-even
alongside the observed workload size. **Then look for the row where it fails** —
in #1056 a short session broke even only at 641 requests and spent 11 there, so
for it the reload is a clear loss. That row is what turns a threshold into an
*advisory* one rather than an enforced one, and reporting it is what makes the
rest of the analysis credible. A tradeoff that wins everywhere usually means the
losing case has not been looked for. See [[size-the-effect-from-the-right-quantity]]
and [[measured-cause-may-invert-the-remedy]].
