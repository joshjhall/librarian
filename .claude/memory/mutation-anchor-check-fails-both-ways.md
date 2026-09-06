---
name: mutation-anchor-check-fails-both-ways
description: "A mutation harness that verifies \"the edit landed\" by re-grepping the anchor gives wrong verdicts in BOTH directions — cmp against the pristine copy instead"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8c18d381-5905-4b08-a734-d468be4e3b1b
  modified: 2026-09-06T22:16:20.894Z
---

A mutation round is only as trustworthy as its "did the edit apply?" check, and
the obvious implementation — grep the anchor before and after — is wrong in
**both** directions. Both fired in one six-mutation round (librarian #936):

- **False negative.** An anchor beginning with `-` is read by grep as an
  **option**: `grep: invalid option -- '$'`. The guard reported *anchor not
  found* and refused. Fix the call (`grep -qF -e "$anchor"`) — but note the guard
  only saved the round by refusing; unguarded, this scores as a **survivor**.
- **False positive.** A mutation that **appends** to its anchor
  (`… ]; then` → `… ] && false; then`) leaves the anchor present as a **prefix
  of its own replacement**, so re-grepping reports "not applied" for a mutation
  that applied correctly.

**Why:** the anchor is a *search key*, not a *state*. Its presence after an edit
says nothing reliable, because replacements routinely contain their own anchors.

**How to apply:** verify with `cmp -s "$PRISTINE" "$FILE"` and treat *file
unchanged* as the only "not applied" signal — it cannot be fooled either way.
Keep the loud refusal: an unapplied mutation runs pristine code and reads as a
survivor ([[crashed-mutation-reads-as-survivor]]). Also do not edit the harness
while a pass is running — the running shell re-reads the file and dies on a
syntax error mid-write.

Related: [[mutation-restore-must-not-be-git-checkout]],
[[mutation-harness-keyed-on-exit-code]].
