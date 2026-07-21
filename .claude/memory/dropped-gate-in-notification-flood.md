---
name: dropped-gate-in-notification-flood
description: "During long orchestrate monitor runs, a burst of checkpoint notifications can bury a plan-gate approval or an unpresented gate; two golems sat idle ~8h. After ANY notification burst, reconcile live gates against gh pr list + panes before trusting the checkpoint's \"live\" state"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4a569e6e-ef19-4017-ab95-d5f8dfddb610
  modified: 2026-07-21T13:18:49.697Z
---

On the 2026-07-20/21 orchestrate run, three golems (406/428/248) sat idle for
**~8 hours**. Root cause was **mine, not the tooling**: a long unbroken burst of
`golem-status --checkpoint` monitor notifications arrived while I was mid-turn.
Buried in that flood were (a) golem-248's plan-gate approval — the operator had
already said "approve option 1" but I **never sent the `tmux send-keys` keystroke**
— and (b) golem-406's plan gate, which I **never even presented** to the operator.
golem-428 meanwhile finished, opened PR #466, and idled at "merge PR 466". All
three showed `TOKENS(Δ)=0` sweep after sweep — the [[frozen-counter-is-done-not-wedged]]
signature — but this time frozen meant *waiting on ME*, a third meaning beyond
done/working/wedged.

**Why it happened:** the checkpoint monitor emits every ~8 min and renders `live`
for a golem parked at a gate (the cache has no gate-state writer for a plan gate).
When many sweeps batch into one turn, an actionable gate event scrolls past among
dozens of no-op status lines and is easy to drop. The push gate-watch DID fire the
original gate events — I just lost them in the volume.

**How to apply:**

1. **A plan-gate approval is not complete until the keystroke lands.** After the
   operator approves, send `tmux send-keys` AND verify the pane left plan mode
   (`⏵⏵ auto mode on`, no modal) in the SAME action. Never consider a gate
   resolved on the approval alone.
2. **After any burst of monitor notifications, reconcile before trusting `live`.**
   Run `gh pr list --state open` + `tmux capture-pane` on each live golem to find
   (a) golems idle at a plan/permission gate, (b) finished golems parked at a
   "merge PR N" prompt. Frozen `TOKENS(Δ)=0` across many sweeps = **go look at the
   panes**, not "still working." This is the same authoritative-state-beats-counter
   rule as [[frozen-counter-is-done-not-wedged]], extended: frozen can also mean
   "blocked on an action I owe it."
3. **Track outstanding gates explicitly** (a short in-turn checklist) when several
   golems gate near-simultaneously, so a second gate arriving mid-approval can't
   silently displace the first. The #446/#447/#248 idle-at-prompt push work makes
   the *tooling* surface this better, but the operator discipline is the real fix.
