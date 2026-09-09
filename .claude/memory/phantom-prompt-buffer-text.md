---
name: phantom-prompt-buffer-text
description: "golem panes sometimes show unsent next-step text pre-populated in the input line; source unconfirmed, verified inert (no Enter sent)"
metadata:
  node_type: memory
  type: reference
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-09-09T00:00:00.000Z
---

Golem tmux panes sometimes show a plausible **next-step instruction** sitting at
the `❯` input line, UNSENT, that neither operator nor orchestrator typed.

Observed 2026-07-24 (wave-2 orchestration):

- golem-446 (post-close, idle): `work the stretch auto-resume in #465`
- golem-494 (mid pre-push suite): `merge it once CI is green`

Observed again 2026-09-09 (4-lane tracks run), three more:

- golem-793 (post-merge, idle): `file the upstream report by hand and close #971`
- golem-705 (post-merge, idle): `closing 705 was right, move on to 898`
- golem-899 (idle, work staged unpushed): `push it`

**Trigger hint (new, 2026-09-09):** all three fired on a golem that had just
**asked the operator a question** and was idle awaiting the answer — and each
phantom line reads as a plausible ANSWER to that specific question. The
2026-07-24 pair fits too (both idle). This is a sharper repro hint than "idle"
alone; it suggests the TUI composing a suggested reply, not random text.

**Verified NOT from orchestration scripts** (re-confirmed 2026-09-09): every
`send-keys` in `plugins/workflow/scripts|hooks` sends only `1`, `Enter`, `BTab`
or `S-Tab` — never free text. Also ruled out that run: zero tmux clients attached
(`tmux list-clients` empty, all sessions `attached=0`), the only other Claude
session on the box had four MCP servers as its sole children (no tmux, no shell),
and no configured hook writes to a pane. Most likely the Claude Code TUI
rendering a suggested next action, not actual pending input.

**Risk:** benign WHILE inert (buffer only submits on Enter, which nothing sends).
BUT if any stray Enter ever reached that pane (misfired send-keys, monitor/script
bug, classifier retry), it would submit an UNAPPROVED command. Two of the five
instances were outward or gate-bypassing actions — `merge it once CI is green`,
and `push it` on a golem that had **explicitly stated** it was withholding the
push pending its portability gate and review cycle 2. So treat a phantom buffer
line as a latent hazard, not noise.

**How to apply:** (1) When reaping/handling an idle golem, DON'T blind-send
keystrokes to "clear" it — `C-u` did not clear it in either run (evidence it's
not editable input), and a stray Enter could submit it. Reap the session instead
(teardown disposes the buffer, confirmed 2026-09-09 on golem-705/793).
(2) Never assume a pane's `❯ <text>` line is something you or the operator
queued. (3) **Do not escalate it as an intrusion** — the 2026-09-09 session
reached "untrusted input channel" on three data points before checking this
file; the memory directory had it documented since July. Read the body, not just
the index ([[read-the-memory-body-not-just-the-index]]). Filed as a low-sev issue
on recurrence. Relates to [[idle-detector-false-positive-own-monitors]] and
[[orchestrate-broker-then-send]] (only directed digit/Enter sends are compliant).
