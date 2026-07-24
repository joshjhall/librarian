---
name: issue-446-golem-status-reliability
description: "#446 golem-status BLOCKED reliability — Bug #2 ghosts + Bug #4 API-death; 2 of 4 modes already fixed"
metadata: 
  node_type: memory
  type: project
  originSessionId: 640198ea-00a1-4592-be2a-17773ad6f0d1
  modified: 2026-07-24T20:35:06.929Z
---

# 446 "golem-status.sh BLOCKED list unreliable" names **4 failure modes**

**2 were already shipped** — always check before scoping: Bug #1 (send-keys stale
gate) = #422 `golem-resolve.sh` + `resolved` event (see [[stale-blocked-false-positive]]);
Bug #3 (`golem-?` unattributed) = #323 `feed_snapshot` orphan drop. Only Bug #2 +
Bug #4 (owner-comment) remained.

**SHIPPED PR #464** (2026-07-20, L3, worktree, PARKED human-merge per
[[auto-mode-blocks-self-merge]]). **Contributes to #446** (not Closes — 2 live ACs
deferred to follow-up #465), per [[umbrella-issue-closes-vs-contributes]].

- **Bug #2 (ghosts)** two layers: (A) `worktree-rm.sh` emits terminal `REAPED:`
  feed event on teardown, forcing `GOLEM_ID=golem-N` (main-checkout basename would
  stamp `golem-?` — same reason golem-resolve.sh forces it); `golem-notify.sh`
  classifies `reaped` via **anchored prefix** (mis-anchor could mask a real gate).
  (B) reader `feed_snapshot_live` in golem-gate-watch.sh cross-checks
  `golem_has_live_trace` (tmux session / `golem-N.json` / `issue-N.json` / worktree
  dir) — covers golems killed without worktree-rm.sh. BLOCKED list inherits via
  `--once` delegation.
- **Bug #4 (silent API death)** = pane matcher (a dead process can't emit its own
  event; Stop hook can't tell died-on-429 from finished). `pane_is_api_error`
  (wider `GOLEM_PANE_ERROR_LINES=40` window, spinner-veto) + `pane_api_error_class`
  (429/5xx retriable, other 4xx terminal). Dispatched in `panes_snapshot` BEFORE
  `pane_is_turn_end` (died pane also paints bare turn-end footer) but AFTER modal
  gates; `died` arm in `pane_liveness_class` for the pull surface.

**Test gotcha:** `feed_snapshot` tests create feed lines for golems with NO
trace; the new ghost filter drops them. Fix = `_stamp_feed_traces` helper stamps a
`golem-N.json` per fixture golem so feed-semantics tests still represent live
golems. Hermetic-tmux stubs need `git` symlinked too (repo_root fails → status_dir
empty → drops everything).

**Adversarial pre-PR review wall-timed-out** at the 40-min ceiling (L3, 1
extension) — partial, can't read `clean`. Recovered 10 findings from
`journal.jsonl` (grep `"type":"result"`), triaged by hand: 2 high scope-drift
(AC#4 + Bug#4 need live verify) were ALREADY handled by Contributes-to + deferral;
folded in the actionable quality nits (Tunables doc, 5xx-class test, trace-KEEP
branch coverage, died liveness-wiring test). no-jq reaped fallback left
covered-by-construction (fixed ASCII literal, numeric $N).

Follow-up **#465** = live 429 DIED flow + multi-golem BLOCKED ground-truth sweep +
(stretch) orchestrator auto-resume of retriable deaths.

**CLOSED code-complete 2026-07-24** (wave-2 golem-446 escalation, operator opt 1):
all 4 modes' CODE is merged (#464 Bug#2/#4, #422 Bug#1, #323 Bug#3) and the golem
verified the #464 functions are still intact in the current tree despite PRs
(#485, #489, #501, #504, #506) all touching the same files; the only open
work was live-verification ACs, which are #465's scope. Golem produced NO PR —
posted a closing summary mapping modes→PRs and closed the issue. LESSON: a
"Contributes to" issue can be fully code-done with only unreproducible-in-session
ACs left; verify the merged PRs before re-implementing (the golem correctly
discovered this and escalated rather than redo shipped work). A no-PR close-out
golem frees its lane slot on issue CLOSE, not a merge.
