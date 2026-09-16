---
name: targeted-gates-miss-what-only-the-suite-checks
description: Running the targeted gate for what you changed can pass while the full suite fails — some gates assert repo-wide properties (file modes, manifests) that no per-area gate covers
type: feedback
metadata:
  node_type: memory
  modified: 2026-09-14T00:00:00.000Z
---

CLAUDE.md advises running the **targeted** gate for what changed rather than the
full suite, because `git push` re-runs everything anyway. That advice is sound
for iteration speed, but it has a gap: a property no per-area gate asserts is
invisible until the whole suite runs.

Measured on #934: a new `plugins/**/*.sh` passed `lint-shellcheck`,
`lint-shell-portability`, its own behavioral suite (56 cases), and four more
targeted gates — then the full suite failed on `tests/lint-skills-agents.sh`,
which requires every bundled plugin script be **executable** (#604). No gate
that reads a script's *contents* checks its *mode*.

**Why:** targeted gates are organized by subject matter (shell syntax, python
lint, this skill's behavior); repo-wide invariants — file modes, manifest
agreement, generated-artifact freshness, fragment-list completeness — are
organized by nobody, so they live in whole-tree gates. Choosing gates by "what
did I touch" selects only the first kind.

**How to apply:** when a change ADDS a file (rather than editing one), run the
full suite once before shipping — new files are exactly what repo-wide
invariants are about, and an edit to an existing file has usually already
satisfied them. Cheap check for the common case:
`ls -l` a newly added `plugins/**/*.sh` and confirm the exec bit. Related:
[[background-task-exit-code-is-the-wrappers]], [[skip-guard-may-outlive-its-dependency]].
