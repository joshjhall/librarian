---
name: parse-error-exits-zero-check-stderr
description: A script that dies at PARSE time exits 0 — its harness never runs; and `bash -n` may only WARN, so a gate keyed on exit code is a tautology
metadata:
  type: feedback
---

A shell script that fails to **parse** never executes a line, so its test harness
never reaches `generate_report` and the shell exits **0**. A CI step reads that as
a pass. This is the [[stale-artifact-makes-the-stub-pass]] family reached through
grammar rather than a missing tool — and unlike a missing tool it has **no 77
sentinel**, because the script never gets far enough to emit one.

When you build the gate against it, measure what `bash -n` actually does before
keying on anything. Measured on bash 5.2, a heredoc nested inside a command
substitution (`out="$(python3 - <<'PY' 2>&1)"`, unparseable on bash 3.2) makes
`bash -n` print `warning: command substitution: 1 unterminated here-document` to
**stderr and still exit 0**. So:

- `if ! bash -n "$f"` — **tautology**. Green on the very file that motivated the
  gate. This is the [[anchored-regex-tautological-test]] shape.
- `[ -n "$(bash -n "$f" 2>&1 || true)" ]` — correct. Non-empty stderr covers
  BOTH a hard `syntax error` (non-zero) and a warning-only diagnostic (zero).
  The `|| true` keeps a hard error from aborting the suite under `set -e`.

**Why:** the failure is invisible in both directions — the broken script reports
pass, and the naive gate against it also reports pass. Two silent layers.

**How to apply:** arm the finished gate against the **pre-fix** file and confirm
it FLAGS, then against the post-fix file and confirm it CLEARS
([[fixture-must-express-the-divergent-case]]). Mutate the scanner three ways —
neutered, exit-code-keyed, always-flag — and confirm each dies on a different arm
([[mutation-round-finds-the-untested-rule]]). And prove the *subject* regained
teeth too: break one assertion and confirm the suite now exits non-zero, since
before the fix it exited 0 no matter what.
