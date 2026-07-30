---
name: rumdl-scope-depends-on-invocation
description: "rumdl's file selection is invocation-dependent — it under-reports on a tree walk (skips gitignored) and over-reports on an explicit non-markdown path (parses .sh as markdown)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b7784e09-7844-4b1e-a469-8c097765285b
  modified: 2026-07-30T04:53:26.161Z
---

`rumdl` does **not** filter by extension. What it lints depends entirely on how
it is invoked, and it fails in **both** directions:

- **Over-reports on an explicit path.** Hand it a non-markdown file and it
  parses that file as markdown. `rumdl check some-script.sh` treats every `#`
  comment as a heading — a clean bash script yielded **4,426** phantom
  MD018/MD022/MD025 rows, the first being the shebang.
- **Under-reports on a tree walk.** `rumdl check .` skips gitignored paths, so
  scratch notes under a gitignored dir are linted by nothing. See
  [[rumdl-issue-ref-line-start]] for that half and its workaround.

**Why:** the two canonical entry points both scope to markdown, so the trap is
invisible until you bypass them — `just lint` runs `rumdl check .` (walk, `*.md`
only) and lefthook sets `glob: "*.md"` **before** `rumdl check {staged_files}`.
Neither ever hands rumdl a `.sh`.

**How to apply:** rumdl is the one **language-scoped** gate in the lint set —
shellcheck / typos / shfmt / actionlint apply or no-op sanely on any file, rumdl
does not. When running the gates over a changed-file list (e.g. ship-issue's
pre-review-gates step), **filter the list to `*.md` first** and skip rumdl
entirely when that subset is empty. Do not pass a changed-file list to rumdl
uniformly with the others.

This matters most feeding a review harness: rows like these are not merely
unconfirmed candidates, they are **wrong**, and reviewers would burn real budget
adjudicating thousands of fake markdown findings in a shell script.

Related: [[rumdl-issue-ref-line-start]], [[no-noverify-fix-the-lint]],
[[pre-review-gates-needs-filelist]].
