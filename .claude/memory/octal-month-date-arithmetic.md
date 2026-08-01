---
name: octal-month-date-arithmetic
description: "date +%m in $(( )) is parsed as OCTAL — aborts under set -e in Aug/Sep only, silently emitting zero findings"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0e233a17-021e-4d60-9845-ff1f92f2f7b1
  modified: 2026-08-01T01:29:41.736Z
---

`$(( ))` treats a leading-zero literal as **octal**, so `date +%m` (zero-padded)
breaks arithmetic in **August and September only** — `08`/`09` are invalid octal
digits. Under `set -euo pipefail` the expansion aborts the whole script, which
for a scanner means **zero findings emitted**, not an error the caller notices.

Found on #609/PR #623 in `check-docs-staleness/patterns.sh:64`; FIXED by #624 /
PR #627 with `CURRENT_MONTH=$((10#$(command date +%m)))`, pinned by a
twelve-month sweep in `validate-docs-detectors.sh`.

**Injecting a month for a test:** stub `date` on PATH (`command date` resolves
through it) — but the stub must answer **every format the caller uses**,
`+%Y-%m` as well as `+%Y`/`+%m`, or the scanner and the fixture disagree and it
reads as a scanner bug. Unset `BASH_ENV` for the child (see
[[devcontainer-bash-env-path-reset]]) or PATH is restored and the would-fail arm
passes vacuously. A PATH stub cannot reach Python — `datetime` ignores it — so
only the bash arm is stubbable.

**Why it hides so well:** it is green 10 months a year, and the local-vs-UTC
split makes it look like a flake — a dev at `2026-07-31` local sees a green suite
while CI at `2026-08-01` UTC is red. When a date-adjacent test fails only in CI,
compare `date -u` to `date` before suspecting the diff.

**How to apply:** any `date +%m`/`+%d`/`+%H` feeding `$(( ))` needs a `10#`
prefix. A fixture that reads the wall clock only proves something during the
months it happens to run — parameterize the month instead. Same family as
[[grep-c-zero-count-exit-1]] (a command whose exit status betrays its output) and
[[die-inside-command-substitution-is-swallowed]].
