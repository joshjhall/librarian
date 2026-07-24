---
name: phantom-prompt-buffer-text
description: "golem panes sometimes show unsent next-step text pre-populated in the input line; source unconfirmed, verified inert (no Enter sent)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 488b0a34-9bc0-433c-bfaa-2b103493faaa
  modified: 2026-07-24T16:47:57.648Z
---

Twice during wave-2 orchestration (2026-07-24) a golem's tmux pane showed a
plausible **next-step instruction** sitting at the `❯` input line, UNSENT, that
neither operator nor orchestrator typed:

- golem-446 (post-close, idle): `work the stretch auto-resume in #465`
- golem-494 (mid pre-push suite): `merge it once CI is green`

**Verified NOT from orchestration scripts:** every `send-keys` in
`plugins/workflow/scripts|hooks` sends only `1 Enter` (plan approval) or a bare
digit — never free text (grep confirmed). So the text is not leaking from
golem-status / gate-watch / resolve / inbox. Most likely the Claude Code TUI
rendering a suggested next action (greyed suggestion), not actual pending input.

**Risk:** benign WHILE inert (buffer only submits on Enter, which nothing sends).
BUT if any stray Enter ever reached that pane (misfired send-keys, monitor/script
bug, classifier retry), it would submit an UNAPPROVED command — and one instance
was an outward `merge` action. So treat a phantom buffer line as a latent hazard,
not noise.

**How to apply:** (1) When reaping/handling an idle golem, DON'T blind-send
keystrokes to "clear" it — `C-u` did not clear it (evidence it's not editable
input), and a stray Enter could submit it. Reap the session instead (teardown
disposes the buffer). (2) Never assume a pane's `❯ <text>` line is something you
or the operator queued. (3) If it recurs with a confirmable source, file a
low-sev issue. Not yet filed — source unattributed. Relates to
[[idle-detector-false-positive-own-monitors]] and
[[orchestrate-broker-then-send]] (only directed digit/Enter sends are compliant).
