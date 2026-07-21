# `golem-status` BLOCKED-reliability verification — issue #446

Tracks the acceptance criteria of
[#446](https://github.com/joshjhall/librarian/issues/446)
("golem-status.sh BLOCKED list unreliable"). The issue names **four** failure
modes; this PR (Bug #2 + Bug #4) is a **partial** delivery — `Contributes to`,
not `Closes`. Bugs #1 and #3 were already shipped in earlier work; a Bug #4
live-fire spot-check is deferred to a follow-up.

## Summary

| AC / mode | What it proves | Status |
| --- | --- | --- |
| AC#1 — send-keys plan gate clears within one sweep | resolved-event supersession | **VERIFIED — prior work** ([#422](https://github.com/joshjhall/librarian/issues/422): `golem-resolve.sh` + orchestrate broker wiring) |
| AC#2 — torn-down golem never BLOCKED after teardown | terminal `reaped` event + reader ghost-filter | **VERIFIED — live (unit)** this PR |
| AC#3 — no `golem-?` rows for resolvable `$GOLEM_ID` | orphan drop + identity ladder | **VERIFIED — prior work** ([#323](https://github.com/joshjhall/librarian/issues/323): `feed_snapshot` orphan drop) |
| AC#4 — BLOCKED matches ground truth in a multi-golem run | end-to-end reliability | **VERIFIED — static + unit**; live multi-golem sweep → follow-up |
| Bug #4 — silent death on a transient API error surfaces as DIED | pane API-error read + retriable/terminal class | **VERIFIED — unit (synthetic pane)**; live 429-mid-run → follow-up |

Two verification strengths are distinguished on purpose: **live/unit** (a
behavior was exercised this run, against real code paths with synthetic fixtures)
vs **static** (source-trace — wiring read and confirmed present but not observed
firing against a real orchestrate session).

## Why some criteria are deferred

Bug #4's true end-to-end — a real Anthropic **429** landing mid-run and the
golem's `claude` process dying at its prompt — **cannot be reproduced
in-session**: it needs a live rate-limit against a real golem in a real tmux
pane. The issue itself notes the pane scrollback is the only ground-truth signal,
so the fix is a pane matcher (`pane_is_api_error`), and the matcher + dispatch +
classification are exercised in-session with synthetic pane text through the
`_pane_rc` / `_run_panes_snapshot_tmux` harnesses. The residual — observing a
real 429 death flow through `--stream-panes` to an orchestrator — is a live
spot-check for a follow-up.

Likewise AC#4's "matches ground truth in a multi-golem run" is asserted at the
unit level (ghost drop + death dispatch + reaped supersession each pinned) but a
live multi-golem `/orchestrate` sweep is the deferred confirmation.

## Bug #2 (AC#2) — torn-down golems ghost as BLOCKED — VERIFIED (unit)

Two layers, both tested:

- **Layer A (source, primary).** `plugins/workflow/scripts/worktree-rm.sh` emits
  a `REAPED:`-prefixed Notification (forcing `GOLEM_ID=golem-N`) after a
  successful teardown; `plugins/workflow/hooks/golem-notify.sh` classifies it as
  the `reaped` event kind, which — like `idle`/`resolved` — is not in the BLOCKED
  set, so it supersedes the golem's stale `gate` on the next sweep.
  - `tests/validate-golem-notify.sh`: `REAPED:` prefix → `reaped`; a mid-message
    `reaped:` stays `gate` (anchoring, mirrors the #422 resolved-masking guard).
  - `tests/validate-golem-scripts.sh`: `worktree-new 51` → `worktree-rm 51`
    writes a `reaped` feed line carrying `golem-51` (not `golem-?`).
- **Layer B (reader, defense-in-depth).** For a golem torn down **without**
  `worktree-rm.sh` (killed by hand, or a stale pre-existing line),
  `golem-gate-watch.sh`'s `feed_snapshot_live` cross-checks `golem_has_live_trace`
  and drops a gated golem with no live tmux session, no worktree dir, and no
  cache file. `golem-status.sh`'s BLOCKED list delegates to `--once`, so it
  inherits the filter.
  - `tests/golem-gate-watch.sh`: a gated golem with no trace is dropped; a gated
    golem with a cache-file trace (live headless golem) is kept.

## Bug #4 — silent death on API error → DIED — VERIFIED (unit)

`plugins/workflow/scripts/golem-gate-watch.sh` adds `pane_is_api_error` (scans a
wider `GOLEM_PANE_ERROR_LINES` window for the `API Error <4xx/5xx>` signature,
vetoed by an active run-spinner) and `pane_api_error_class` (retriable 429/5xx vs
terminal auth/quota). `panes_snapshot` dispatches it **before** `pane_is_turn_end`
(a died pane also paints the bare turn-end footer, so the more-specific death
wins) and after the three modal gate matchers (a modal gate still wins).
`pane_liveness_class` gains a `died` arm so the pull `--once-liveness` /
`golem-status.sh` liveness section reports `⚠ died — API error` instead of a plain
`idle`.

- `tests/golem-gate-watch.sh`: `pane_is_api_error` matches 429/403, spinner
  vetoes, prose without a code does not match; `429 → retriable`, `403 →
  terminal`; `panes_snapshot` emits the DIED label end-to-end before turn-end, and
  a plan overlay still wins over a scrollback error.

## Local gate results (this run)

| Gate | Result |
| --- | --- |
| `tests/golem-gate-watch.sh` | 33/33 |
| `tests/validate-golem-notify.sh` | 22/22 |
| `tests/validate-golem-scripts.sh` | 121/121 |
| `tests/lint-shell-portability.sh` | 93/93 |
| `tests/lint-shellcheck.sh` | 93/93 |
| `tests/run-all.sh` | see PR checks |

## Deferred to follow-up

- **Live 429 death flow** — observe a real transient API death surface as DIED
  through `--stream-panes` in a real golem session (Bug #4 live spot-check).
- **Live multi-golem ground-truth sweep** — run `/orchestrate` with ≥2 worktree
  golems, tear one down, and confirm the BLOCKED list matches the panes (AC#4
  live).
- **Auto-resume on retriable death** — the retriable/terminal classification is
  emitted for an orchestrator to act on; wiring an automatic resume of a
  transient death is out of scope here.
