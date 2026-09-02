---
name: scratch-file-under-memory-fails-the-push
description: A scratch .md under .claude/memory/tmp/ is linted by rumdl even though gitignored — it can fail the pre-push suite
metadata: 
  node_type: memory
  type: project
  originSessionId: 9c400633-e99b-465d-ae23-722ebd1f208a
  modified: 2026-09-01T18:29:28.337Z
---

`tests/run-all.sh` has a **Markdown lint (.claude/memory/)** stage that runs
`rumdl` and `typos` over `.claude/memory/` with **gitignored files included**. So
a scratch note dropped in `.claude/memory/tmp/` — a PR body, a probe script's
notes — is linted like committed prose and can **fail the whole pre-push suite**,
costing a full ~520s cycle for a file that is never committed.

**Why:** the stage deliberately ignores gitignore so agent-written memory cannot
rot unchecked. The cost lands on scratch files that happen to live there.

**How to apply:** when staging scratch prose for a `gh pr create --body-file`,
write it **outside** the repo (`/tmp/`) rather than under `.claude/memory/tmp/`,
and delete any scratch file there before pushing. The failure I hit was `MD018`
(no space after `#`) on a line beginning with an issue reference like `#742` —
rumdl parsed it as a heading. Reflowing the line so the `#N` is not line-initial
fixes it; so does keeping the file out of that tree.

Note the pre-push failure output points at the *stage*, not the file — grep the
run log for `Failed:  [1-9]` to find the real line. Related:
[[push-hang-is-the-prepush-suite]], [[prepush-hook-already-runs-the-suite]],
[[explicit-path-still-honors-gitignore]].
