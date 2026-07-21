---
name: frozen-counter-is-done-not-wedged
description: "A golem's frozen top-level TOKENS(Δ)=0 in golem-status --checkpoint usually means DONE-and-idle-at-prompt (the #447 stall class), NOT wedged; check PRs/disk before calling a wedge"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 4a569e6e-ef19-4017-ab95-d5f8dfddb610
  modified: 2026-07-21T03:17:06.058Z
---

During a 2026-07-20 `/orchestrate tracks` L3 run I misread three golems whose
`golem-status.sh --checkpoint` **TOKENS(Δ)** went to `+0` for many sweeps as a
**review-wedge** (unbounded ship-issue review re-running without landing). I
escalated a takeover question to the operator. **I was wrong** — all three had
already **finished and shipped**: `gh pr list` showed PRs #453/#455 created and

# 456 already merged; the panes read *"merge PR #455 when ready"* and *"Change

Closes #411 to Contributes to"*. The frozen main-thread counter meant
**done-and-idle-at-the-prompt** — the exact stall class #447 was built to detect,
which is invisible to the pane/feed gate-watch push channels (so I got no PR
notification and inferred wedge from silence).

**Why:** `TOKENS(Δ)=0` is ambiguous — it means the *main thread* isn't burning,
which is equally true of (a) a golem spinning in a sub-workflow, (b) a wedge, and
(c) **a finished golem sitting idle at its prompt**. The push gate-watch does not
yet emit the turn-ended/idle signal (that IS #447/#452), so "no PR notification +
frozen counter" is NOT evidence of a wedge.

**How to apply:** before ever calling a wedge or offering a takeover on a frozen
counter, check the **authoritative** surfaces FIRST — `gh pr list --state open`
(+ `--state all --head feature/issue-{N}` for a `[gone]` branch = already
merged), and the worktree disk (`git log origin/main..HEAD`, `git status -sb`,
deliverable files). A golem that committed + pushed + opened a PR is DONE, not
stuck. Trust PR/label/disk state over the token-burn counter — burn is a Mode-2
liveness *hint*, not a completion signal. Ties to [[review-wedge-root-cause]]
(real wedges exist, but frozen≠wedge) and [[stale-blocked-false-positive]]
(pane/counter signals mislead; authoritative state wins). The shipped work parked
for human merge is the [[auto-mode-blocks-self-merge]] case.
