---
name: send-keys-rc-proves-nothing
description: "tmux send-keys returns 0 for an unrecognized key name — it types the literal text instead; assert the key ARGUMENT, never the exit status"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 732dcb29-edfd-4578-b070-8cd221a9a696
  modified: 2026-08-04T22:02:30.874Z
---

`tmux send-keys` exits **0** whether or not it recognized the key name. An
unrecognized name is not an error — tmux types it as literal characters into the
pane. So a passing `send-keys` proves only that tmux delivered *something*, never
that the intended keystroke happened.

Measured on tmux 3.5a with `cat -v` behind the pane:

- `send-keys S-Tab` → `^I` — a **plain Tab**, the Shift modifier silently dropped
- `send-keys BTab` → `^[[Z` — the real CSI Z shift-tab

Both returned rc=0. `S-<name>` modifier syntax needs extended-keys support; the
traditional table name for shift-tab is `BTab`.

**Why:** shipped in `golem-mode-check.sh` (#659) as `S-Tab`. The check would have
detected mode drift correctly, typed a bare Tab into the golem's prompt, then
escalated after exhausting its retry budget on a golem it could have fixed — a
tool whose whole purpose is "never assume the keystroke worked", defeated by
assuming the keystroke worked. Caught by the review harness, not by any test:
the tmux stub treated *any* `send-keys` call as success, so the key name was
never asserted.

**How to apply:** when a test stubs `send-keys`, assert on the **key argument**
(`assert_contains "$log" "BTab"` **and** `assert_not_contains "$log" "S-Tab"`) —
a stub keyed only on "was send-keys called" cannot see this class of bug. In
production code, verify the *effect* by re-scraping the pane rather than trusting
the send's rc. Verify a key name empirically (`cat -v` behind a throwaway
session) instead of reasoning about which tmux version supports which syntax.

Related: [[comment-asserts-intent-not-code]] — the comment block above this call
described the exact trap the call then fell into.
