---
name: untracked-file-survives-git-checkout-restore
description: A mutation restore via `git checkout --` is a silent no-op on an untracked file — the mutation stays live and the next green run is measuring the mutated subject
metadata:
  node_type: memory
  type: feedback
---

`git checkout -- <path>` on a file git does not track **fails, prints nothing
useful, and changes nothing** — and under `|| true` (or as the last command of a
`&&` chain) the caller reads success. A mutation applied to a brand-new file
therefore **stays applied** across what looks like a clean restore, and every
subsequent run measures the mutated subject.

This is nastier than the already-recorded
[[mutation-restore-must-not-be-git-checkout]] hazard, which is about
`git checkout` reverting a *tracked* file to HEAD and destroying the uncommitted
fix. Same command, opposite failure: there the restore does too much, here it
does nothing at all. A mutation round on a feature branch hits both, because the
round's subjects are a mix of edited-tracked and newly-added-untracked files.

**Why:** the tell is absence, not error. `git status --porcelain` still shows the
file as `??` after the "restore", which reads as normal for a new file — so
nothing about the output says the revert did not happen.

**How to apply:** snapshot-copy every mutation subject before the round
(`cp <f> $SNAP/`) and restore by `cp` back, for tracked and untracked alike —
never branch on tracked-ness, which is one more thing to get wrong. Then **verify
the restore landed**: `diff -q $SNAP/<f> <f>`, or re-grep for the mutated string
and assert zero hits. A round that ends with an unverified restore has no idea
which subject it was measuring, and its later green results are worthless.
