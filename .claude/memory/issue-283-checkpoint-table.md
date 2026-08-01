---
name: issue-283-checkpoint-table
description: "#283 (PR #414): golem-status.sh --checkpoint compact per-track status+burn table — design, the two blocking-review rounds, and the run-all GIT_DIR-leak hardening"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2ee5cc43-9890-496a-924c-3cd117d9ac0d
  modified: 2026-08-01T04:13:39.804Z
---

Issue #283 SHIPPED as PR #414 (2026-07-19, on a worktree from main, L2). Added a
`--checkpoint` render mode to `golem-status.sh`: a compact per-track table
(TRACK·GOLEM·ISSUE·STAGE·ELAPSED·TOKENS(Δ)·PR·CI·REVIEW·STATE) + batch-totals
footer (Σtokens, rate/hr, live/blocked/shipped), for the orchestrator monitor
sweep. Filed follow-up #415 for deferred coverage nits + Mode-3 `started` stamp.

**Key design facts** (grounded, may outlive the code):

- Burn + elapsed data ALREADY EXISTED — reuses [[token-scrape-transcript-dedup]]
  (#371 `top_level_tokens`) for burn and the schema's `started` for elapsed; the
  issue's speculative pane-footer scrape is superseded. NO schema change.
- `--checkpoint` REPLACES the verbose render per sweep (mutually exclusive): the
  token persist is the frozen-counter baseline; running both would zero the Δ.
- Extracted `scrape_and_persist_tokens` helper (echoes `state\tcur\tprev\tat`,
  state ∈ container|unknown|first|advancing|reset|frozen) — the SOLE cache-token
  writer, driving BOTH the verbose block and the checkpoint column; the #371
  tests gate the refactor.
- A count DROP across sweeps = `reset` (fresh session post-/clear), excluded from
  Δ — never a negative delta. Persisted prior is numeric-guarded against
  non-digit / leading-zero-octal ("089") / >18-digit 64-bit-overflow corruption
  (co-written cache → degrade to a safe `first`, never a bash arith error that
  leaks/drops the row).
- Rows group by lane via a `tracks.json` JOIN on `.issue` (NO `track` field on
  golem cache); absent tracks.json → one untracked group. Latent bug fixed:
  tracks.json was NOT excluded from the golem-row glob (only pool.json was).
- Attention markers ⚠ BLOCKED/CI/gone ride the STATE column as plain text (never
  ANSI); priority BLOCKED>CI>gone. `session_gone` needs the `!= "?"` guard (an
  issue-less row's "?" fallback is a single-char glob wildcard). PR/CI/Review are
  cache mirrors captioned non-authoritative (script stays gh-free).

**Adversarial pre-PR review took 3 cycles** (2 blocking rounds): cycle 1 →
negative-delta bug + session-gone/ELAPSED gaps; cycle 2 → a HIGH security finding
(unguarded persisted token value → arith error drops row, reproduced live);
cycle 3 → clean (blocking:[]), only deferrables. The review reproduces bugs
locally so each cycle ran 20-60 min.

**Two flakes hit + HARDENED this session** (the reliability ask):

1. `typos` pre-push gate blocked on a mis-spelling ("unpars-eable" →
   "unpars-able") in #413's code that the rebase pulled into my touched file —
   [[typos-gate-blocks-push]]. Fixed the spelling (also fixes it on main). NB:
   even prose that NAMES the bad token trips the gate, so hyphenate it in notes.
2. run-all.sh GIT_DIR-leak: the lefthook pre-push hook exports GIT_DIR into
   run-all.sh's env → sandbox `git` calls resolve against the OUTER repo →
   2 config-scrub tests (#376) fail under `git push` but pass on a bare run
   ([[golem-gate-watch-host-leak]] class). DURABLE FIX: run-all.sh now unsets
   GIT_DIR + the 6 sibling git vars ONCE at the shared entry point (top of file),
   so no test is ever hook-env-sensitive again; the 2 tests also got GIT_SCRUB at
   their bare-git steps. Verified: run-all passes with GIT_DIR+GIT_WORK_TREE set.

Rebased onto origin/main (conflicted with #413 which also touched
golem-status.sh + validate-golem-scripts.sh — both additive, kept both sides;
merged suite = 105/105).
