---
name: explicit-path-still-honors-gitignore
description: "Passing a DIRECTORY to rumdl/typos still applies .gitignore — only an explicit FILE is exempt, so a reachability gate needs --respect-gitignore=false / --no-ignore"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d282d6e2-265f-4046-adc3-50e27ce0b45a
  modified: 2026-08-10T22:26:45.094Z
---

A linter's "explicit paths are exempt from gitignore" promise covers an explicit
**file**, not a **directory it then walks**. Both rumdl and typos re-apply
`.gitignore` to every file they discover under a directory argument.

So the obvious fix for "this tree is never linted" — pass the directory
explicitly — silently keeps the exact blind spot it was written to close, and
reports green while doing it. Measured on `.claude/memory/` (#578): `rumdl check
.claude/memory/` scanned **144 of 145** files, missed a planted MD018 under the
gitignored `tmp/`, and exited 0. With `--respect-gitignore=false` it scanned 145
and caught it. `typos` on the same tree: **0 hits** vs **3** with `--no-ignore
--hidden`.

**Why:** a gate over gitignored files is the one case where the tool's default
walk and the gate's purpose directly contradict each other. Believing the
exemption docs without measuring produces a gate that is inert in precisely its
intended scope — the [[gate-and-evidence-converge-tautology]] failure one layer
up, since the gate's own passing output is the evidence it is working.

**How to apply:** when writing a lint gate whose whole point is reaching
untracked/ignored files, **arm it before trusting it** — plant a defect in the
ignored subtree, confirm the gate fails, then remove it and confirm it passes.
Count the files scanned: an off-by-one against `find <dir> -name '*.md' | wc -l`
is the tell. Never infer coverage from a clean run. Related:
[[measure-suppression-before-keeping-it]].
