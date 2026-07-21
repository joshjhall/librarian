---
name: issue-447-turn-end-pane-push
description: "#447 SHIPPED PR #455 (parked human-merge) — turn-ended/idle-at-prompt now pushed on the --stream-panes gate-watch channel; confirm_turn_end subshell-state bug + wall-timeout-partial park"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3393af5c-9977-48c3-92b9-0faa33f8cc9e
  modified: 2026-07-21T01:17:19.638Z
---

# 447 SHIPPED as **PR #455** (2026-07-20, L3, PARKED for human merge). Made the

turn-ended/idle-at-prompt stall (a golem that finished its turn and sits at an
empty prompt — e.g. commit signing halted on a locked vault) visible on the
PROACTIVE PUSH gate-watch stack, which previously only surfaced it pull-only via
`golem-status.sh`/`--stream-liveness`.

**Design (chose issue's Fix 2 over Fix 1):** folded a turn-end signature into
`panes_snapshot()` (the `--stream-panes` source) so it flows through the existing
`emit_transitions` dedup. Did NOT arm `--stream-liveness` as a push Monitor (Fix
1): that channel is a POSITIVE heartbeat, deliberately NOT transition-deduped, so
it re-emits every golem every 60s and would flood/auto-stop the Monitor push arm.
New `pane_is_turn_end()` mirrors the GLYPH arm of `pane_liveness_class`
(footer-anchored per #246, requires `⏵⏵ auto mode on` glyph, spinner checked
first) as the LAST-RESORT branch after plan-gate/permission-gate/fork.

**CRITICAL BUG caught by manual test (not review):** the two-poll debounce
`confirm_turn_end()` mutates module state (`PENDING_TURN_END`). My first cut
called it as `emit_transitions "$(confirm_turn_end "$(panes_snapshot)")"` — the
`$(...)` runs it in a SUBSHELL, so the pending-poll state is discarded every tick
and the debounce NEVER confirms. Fix = same idiom `emit_transitions` uses: the
function writes a global (`CONFIRMED_SNAPSHOT`) instead of printing, and the drive
arm runs BOTH `confirm_turn_end` and `emit_transitions` in the CURRENT shell (only
`panes_snapshot` is the subshell). Lesson: any bash fn threading cross-call state
must run in the caller's shell, never inside `$(...)`.

**Two-poll confirmation** (`confirm_turn_end`) was a cycle-1 BLOCKING review
finding: the issue body explicitly asks the idle signature be "confirmed across
two consecutive polls to avoid firing on a normal turn boundary" — my single-poll
matcher would false-fire on a golem momentarily between turns. Debounce suppresses
the idle line on poll 1, passes it on poll 2; real gates pass through immediately.

**Adversarial pre-PR review:** cycle 1 → 1 blocking (single-poll) FIXED + 4
deferrable (folded in the cheap correct ones: doc-vs-code "mirrors idle arm"
comment softened to glyph-only; deferred the /usr/bin sweep #228 + macOS-timeout
bonus as out-of-scope). Cycle 2 (reviewing the debounce) → ZERO blocking, 3
low-sev test deferrables (all folded: multi-golem single-call test + chained
drive-arm sequence test + fixed a test-comment misattribution about WHEN pending
clears). Cycle 2 WALL-TIMED-OUT at the 40-min L3 ceiling during classify →
PARTIAL cycle → `clean` forced false → **merge invariant parks for human merge**
even at L3 (never merge on a partial cycle). Recovered partials via
`recover-journal-partials.sh <transcriptDir>/journal.jsonl`.

Bonus item (macOS `timeout(1)`) premise was STALE: wall-time section uses
caller-side TaskOutput polling not shell `timeout(1)`, and `golem-launch.sh`
already guards `timeout`/`gtimeout` via `command -v`. No change; noted in commit.

See [[wall-timeout-decision-helper]], [[usr-bin-hardcoding-golem-scripts]],
[[auto-mode-blocks-self-merge]].
