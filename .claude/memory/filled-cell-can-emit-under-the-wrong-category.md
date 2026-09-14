---
name: filled-cell-can-emit-under-the-wrong-category
description: In a coverage matrix an `M` cell that mis-files its evidence hides worse than an honest `—` — audit filled cells by column-name match, not just empty ones
type: feedback
metadata:
  node_type: memory
---

In a per-language x per-category support matrix, an UNCOVERED cell (`—`) is the
honest, visible gap — it reads as "not scanned" and invites someone to fill it.
A COVERED cell (`M`) whose detector fires under the **wrong category** is worse:
the matrix says that column is handled, so nothing ever prompts a second look,
and the emitted finding actively reads as evidence of a *different* defect.

Worked example (#871, `check-lifecycle`'s Go arms). The stated gap was Go's
`unpaired-listener` cell, marked `—`, and it drew all the attention. The real
defect was one column to the left: `terminate-without-kill` keyed on the bare
token `os.Interrupt`, but in Go that token is not an independent send site — its
ordinary spelling is as an argument to a registration,
`signal.Notify(c, os.Interrupt)`. The scanner was filing a listener registration
under the terminate category, at `M`, silently, for as long as the arm existed.

**Why:** an audit that asks only "which cells are empty?" is structurally unable
to find this — it walks the `—` cells, and the `M` cells are exactly the ones it
treats as settled. The empty cell is self-reporting; the mislabeled one is not.

**How to apply:** when auditing a coverage matrix, ask of every FILLED cell
*does what this cell emits actually match its column's name?* — read the arm
against a real trigger for that category rather than confirming that something
non-empty comes out. Do that before treating the `—` cells as the whole todo
list.

A second, narrower point from the same fix: re-keying a wrong-category arm onto
a fresh token can **reproduce the bug under the new name** when that token is
*also* a common registration idiom — `syscall.SIGTERM` appears as
`signal.Notify(c, syscall.SIGTERM)` just as readily as `os.Interrupt` did. A
token ambiguous between "independent send site" and "registration argument"
needs the registration explicitly **excluded**, not merely a better token.
[[anchor-binds-to-grep-n-prefix]] carries the mechanics of spelling that
exclusion (unanchored, since on the bash side it runs over `grep -n` output).

[[parity-gate-hides-shared-defect]] is the sibling shape one level up: there a
summary signal reads "agreed" while both impls are wrong; here a single impl's
own label is wrong and the matrix reads "covered".
