---
name: splitting-a-file-surfaces-masked-lint
description: "Splitting a monolith makes per-file linters find real bugs the monolith masked — treat each new warning as a finding, not noise"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 5d4f27be-4b8b-4fa0-b825-01bf01cb2b15
  modified: 2026-07-30T15:28:34.142Z
---

shellcheck (and most linters) analyse **one file at a time**. In a 5,787-line
monolith a variable assigned in one test and coincidentally read by an unrelated
sibling looks "used", so SC2034 never fires. Split the file and the two land in
different fragments — the warning appears, and it is pointing at a **real**
defect.

Concretely (#564): `tests/validate-golem-scripts.sh`'s two `#368` fail-loud tests
captured the script's combined output into `out` and asserted only the exit code.
"Fail **loud**" means non-zero **plus an actionable message**, so half the
contract was untested — a silent non-zero abort would have passed. The monolith
hid this because a *different* test's `$out` read satisfied shellcheck. Fixed by
asserting the diagnostic; verified non-vacuous by silencing it (new assertion
fails, exit-code assertion still passes — exactly the gap).

**Why:** two of the three genuine defects in that PR were surfaced by a linter,
none by the adversarial reviewers. On a move-only refactor the repo's own gates
outperform reviewer findings, because there is little new logic to reason about.

**How to apply:** during any file split, run the per-file linters **before**
reaching for a suppression, and triage each new warning as a candidate bug. Only
after confirming the consumer is genuinely in another file should you add
`# shellcheck disable=SC2034` — and then audit the suppressions mechanically
(grep each name in the fragment dir) so none hides a truly dead variable. Also
expect SC2148 on sourced fragments (add `# shellcheck shell=bash`) and SC1090 on
a runtime-composed `source` loop (`# shellcheck source=/dev/null`).

Related: [[comment-asserts-intent-not-code]] — same shape, a claim the code does
not actually make.
