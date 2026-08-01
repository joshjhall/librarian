---
name: footer-anchored-pane-matchers
description: "golem-gate-watch pane matchers MUST anchor on the footer tail, not the whole pane; the 8-line window boundary is exact, and the env override must be set before source"
metadata: 
  node_type: memory
  type: project
  originSessionId: b3100c69-fe8e-4fa0-9335-e1a0ad5da29c
  modified: 2026-08-01T04:19:15.901Z
---

`golem-gate-watch.sh` classifies a golem's tmux pane with five matchers —
`pane_is_gate`, `pane_is_plan_gate`, `pane_is_fork`, `pane_is_turn_end`, and
`pane_liveness_class`. All five MUST match against the **footer tail**, not the
whole captured pane:

```bash
footer="$(tail -n "$pane_footer_lines" <<<"$1")"; case "$footer" in ...
```

**Why:** a whole-pane `case "$1"` false-fires whenever a trigger string merely
appears in scrollback — editing the script, writing fixtures, `cat`-ing a file
— pushing a phantom plan/permission gate. `pane_is_fork` and
`pane_liveness_class` got this protection in #246; `pane_is_gate` and
`pane_is_plan_gate` predated it and were retrofitted in #452 (PR #457) — after
issue #447 added footer-anchored `pane_is_turn_end` without retrofitting the
two older ones. The deliberate exception is `pane_is_api_error` (#446) — it keys its
primary match off `$pane_error_lines`, using the footer only for its
spinner-veto guard.

**The window boundary is exact — no fencepost slop** (verified empirically
against the real sourced matchers, #459 / PR #480): with the default 8-line
window, trigger phrase + **7 filler = 8 lines** is INCLUDED (rc 0); phrase +
**8 filler = 9 lines** is EXCLUDED (rc 1). The `<<<` here-string's trailing
newline is the off-by-one trap to watch.

**How to test them** (#458 / PR #479):

- The window is `${GOLEM_PANE_FOOTER_LINES:-8}`, read at **source time**. Set
  the env var BEFORE `source` — assigning `pane_footer_lines=12` directly
  bypasses the `${VAR:-default}` wiring you meant to test. Use the `_pane_rc`
  helper, which sources the script in a subshell so an env prefix reaches it.
- `export` the var in that subshell to silence shellcheck SC2034 (a sourced
  reader is invisible to shellcheck).
- `pane_liveness_class` returns a **class string**, not an rc — capture stdout
  and assert the class; the other four return exit codes.
- Test both directions: shrink to 3 hides an in-window trigger, enlarge to 12
  reveals an out-of-window one.

Open follow-up **#481**: the exact edge pair is pinned only for `pane_is_gate`
and `pane_is_plan_gate`; the other three share the same `tail -n` idiom with
only coarse cases, so a regression to the shared idiom in one of them would not
be caught.

Related: [[test-assert-blocked-list-not-feed-echo]],
[[gate-watch-misses-standing-gates]].
