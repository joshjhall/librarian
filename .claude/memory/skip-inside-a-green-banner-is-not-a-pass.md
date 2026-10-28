---
name: skip-inside-a-green-banner-is-not-a-pass
description: "\"All test stages passed\" can sit on top of a [SKIP] for the exact gate your change needed — grep the run for [SKIP] and ask whether the skipped gate covers what you touched"
type: feedback
metadata:
  node_type: memory
  originSessionId: bbc72ba7-7a06-48df-83d0-9ff560db09c5
  modified: 2026-10-27T22:10:50.775Z
---

`run-all.sh` renders a gate whose tool is absent as `[SKIP] … did not run` (the
77 sentinel), and a skip does **not** fail the suite — so the closing banner
still reads `All test stages passed`. That banner is a verdict about the gates
that **ran**, not about your change.

Measured on #1247: the pre-push suite printed `All test stages passed`, I pushed,
and CI went red on `agnix error-free` — agnix had flagged prose this PR wrote.
The local log held `[SKIP] agnix error-free — did not run` because agnix is not
installed in the devcontainer. The one gate that inspects new skill prose was the
one that did not run, and the banner gave no sign of it.

**Why:** the sentinel exists so a missing tool reads as a skip rather than a
pass (#538/#571) — but only to someone who reads the per-stage lines. The banner
aggregates the skip away. Same silence-reads-as-a-pass shape as
[[vacuous-scan-reads-as-a-clean-verdict]] (empty corpus) and
[[background-task-exit-code-is-the-wrappers]] (wrapper exit code), reached
through stage aggregation instead.

**How to apply:** after any green suite run, `grep '^\[SKIP\]'` the captured
log. For each skipped gate, ask whether it covers a file type the change touched
(agnix → `CLAUDE.md`/`AGENTS.md`/`plugins/**/*.md`; ruff → `*.py`; shellcheck →
`*.sh`). If it does, the change is **unverified** on that axis: say so, and treat
CI as the first real run of that gate rather than a formality. Related:
[[agnix-reads-angle-bracket-placeholders-as-xml]].
