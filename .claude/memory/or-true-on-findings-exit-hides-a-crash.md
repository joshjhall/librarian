---
name: or-true-on-findings-exit-hides-a-crash
description: "`|| true` on a tool that exits non-zero on FINDINGS also swallows a CRASH, and a crash's empty output reads as a clean scan forever — validate the artifact instead"
type: feedback
metadata:
  node_type: memory
  originSessionId: 148628b2-70e3-48fa-af65-b354e70a89e4
  modified: 2026-11-09T18:59:13.417Z
---

Linters and scanners (agnix, many SARIF producers) exit non-zero both when they
**find issues** (output valid, must be consumed) and when they **crash** (bad
flag, panic, unparsable config, incompatible pin bump — output empty or
invalid). A blanket `|| true` treats both as success, so a crash becomes
"0 findings" with no signal, indefinitely.

Caught by the adversarial review on #399 (PR #460), the agnix SARIF
code-scanning workflow. The fix there, still in
`.github/workflows/code-scanning.yml`: keep tolerating the exit status, but gate
the upload on the artifact — `[ -s agnix.sarif ] && jq -e '.runs' agnix.sarif` —
and emit a `::warning::` naming "crash or empty output" when it fails, rather
than uploading nothing silently.

**Why:** the exit code cannot separate the two cases, but the artifact can. This
is the silence-reads-as-a-pass shape ([[vacuous-scan-reads-as-a-clean-verdict]]).

**How to apply:** whenever a tool's non-zero exit is expected, replace the
`|| true` reasoning with "tolerate the status, **validate the output**":
non-empty, parses, has the expected top-level structure. For a pure validity
check prefer `jq empty` ([[jq-validate-empty-vs-e]]); `jq -e '.runs'` is right
here because it also asserts the structure.
