---
name: split-verify-proves-the-split
description: After a decomposition, run ship-issue/split-verify.sh — it mechanically proves the split lost nothing, and a reviewer will ask for it
metadata:
  type: feedback
---

When a change **extracts** code into a new file, run
`plugins/workflow/skills/ship-issue/split-verify.sh <pre-split-snapshot>
<post-split-original> <new-file>...` before opening the PR. It emits a
`split-verified` row proving LOC conservation, that every top-level unit survived,
and that no call site dangles — or names exactly what was lost.

Get the first argument from git, not from memory:
`git show origin/main:<path> > /tmp/before.sh`. The FIRST result argument must be
the post-split original; the rest are the files content moved into (the
distinction is load-bearing for its markdown-reachability check).

**Why:** a passing test suite shows the surviving code works; it cannot show that
nothing was dropped on the floor — a unit deleted along with its only caller
leaves every test green. On #800 the tool returned `672 -> 679 production LOC
across 2 files, all 17 top-level units preserved, no dangling references` in
seconds, which is a stronger claim than the whole suite makes. The review harness
asked for it by name at HIGH certainty, so running it first also pre-empts a
deferrable finding.

**How to apply:** treat it as a standing step of any extraction, alongside the
before/after output diff. The two are complements — the output diff proves
behavior is unchanged, `split-verify` proves *content* is unchanged. Related:
[[render-diff-before-and-after-an-extraction]], [[blocking-empty-is-not-nothing-to-fix]].
