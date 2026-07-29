---
name: rumdl-issue-ref-line-start
description: "a line STARTING with #NNN is parsed as a malformed heading (MD018) — never begin a wrapped line with an issue ref; reflow the sentence"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 33c5bf10-08a5-4c5a-8d5b-ce6c36897448
  modified: 2026-07-29T19:34:13.893Z
---

Never let a line **begin** with `#NNN`. Markdown reads a leading `#` as a
heading, so `#549-shaped diff while…` trips `MD018 No space after # in heading`.
It happens on *wrapped* prose lines, where the ref lands at the start by
accident of where the text broke — which is why it is easy to write and easy to
miss on reread.

**Why:** it is not a style nit. `rumdl` and `typos` gate the pre-push hook and
fail the WHOLE push, and the "fix" that suggests itself (`rumdl fmt`) is
forbidden here — its autofix turns the ref into an actual heading, corrupting
the sentence. So the cheap-looking violation costs a hand-repair later.

**How to apply:** reflow so the ref is never first on a line — reword
(`a diff shaped like #549's`), or add a lead-in word (`Namely #544 (cycle 2)…`).
Prefer rewording over re-wrapping: the next edit re-wraps the paragraph and can
push a different ref to column 0. The same guard applies to `.claude/memory/`
notes and gitignored scratch files, not just committed docs — I have written
this bug into a memory file *about* rumdl.

Do not wave these away as "pre-existing." In a multi-issue batch the
pre-existing ones are usually mine from an earlier session; check `git log` /
the batch notes before classifying a finding as someone else's.

Related: [[rumdl-nested-sublist-under-numbered]], [[no-noverify-fix-the-lint]],
[[typos-gate-blocks-push]].
