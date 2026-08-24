---
name: redirect-order-leaks-the-diagnostic
description: "`>>\"$f\" 2>/dev/null` opens the file FIRST, so a failed open still prints to the live stderr — absorbed failure, unabsorbed noise"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 956ca71e-7925-484d-98d4-227c314aa2a5
  modified: 2026-08-22T23:05:49.340Z
---

`cmd >>"$f" 2>/dev/null || true` does **not** silence a failed open. Bash applies
redirections **left to right**: the append is attempted while stderr is still the
terminal, so `Is a directory` / `Permission denied` is printed, and only *then*
is stderr pointed at /dev/null. The `|| true` absorbs the exit status; nothing
absorbs the message. The result is an alarming error in the middle of a run that
is otherwise fine.

Write `cmd 2>/dev/null >>"$f" || true` — stderr redirected **before** the open.

**Why:** found in #741, in a `$GITHUB_STEP_SUMMARY` append whose whole purpose
was to be a quiet best-effort nicety. Six write sites had it (one in
`tests/run-all.sh`, four across the two workflows, found only because a reviewer
grepped the siblings). Every rc-based assertion passed on all of them, because
rc really is 0 — the defect lives entirely in the output stream.

**How to apply:** for a best-effort write, assert **silence**, not just
non-fatality — put `assert_not_contains "$out" "Is a directory"` beside the
`assert_equals "0" "$rc"`. An rc-only assertion is vacuous here: it passes with
AND without the fix, which is exactly why the first version of that test caught
nothing. Make the target fail with a **directory**, not `chmod 000` — root can
write a mode-000 file and CI containers routinely run as root, so a
permission-based fixture silently stops failing there. See
[[harden-one-knob-grep-every-sibling]] and
[[gate-and-evidence-converge-tautology]].
