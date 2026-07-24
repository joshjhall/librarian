---
name: issue-489-liveness-dedup
description: "#489 transition-dedup golem-gate-watch --stream-liveness (L1); review caught a self-inflicted set-u arithmetic crash regression I introduced while fixing the sibling knob"
metadata: 
  node_type: memory
  type: project
  originSessionId: a6ebd360-734e-4cfd-9c91-9a21c08f2753
  modified: 2026-07-24T04:58:29.893Z
---

**#489** (severity/high, effort/medium, type/refactor) SHIPPED + MERGED — PR #509
squash-merged to main (commit 71e9fd0), issue auto-closed. L1 run.

**What:** `--stream-liveness` re-emitted one line per golem every 60s
unconditionally (the only streaming channel not routed through
`emit_transitions`); #485 made it the default orchestrate surface so the flood
lands in live context. Fix = give liveness the SAME per-golem dedup the gate
channels already have: new `liveness_stabilize()` strips the volatile `_fmt_age`
(Nm/Ns) from the two mtime lines so a steady class is byte-identical
tick-to-tick → `emit_transitions` (UNCHANGED, reused verbatim) suppresses it.
Plus `liveness_summary()` = one aggregate fleet line as the slow positive
heartbeat, `GOLEM_LIVENESS_SUMMARY_INTERVAL` (default 900s, 0 disables). Pull
view (`--once-liveness`, golem-status.sh) + gate channels untouched. See
[[issue-485-monitor-event-driven]] (made this the default), [[token-burn-audit-2026-07-21]].

**REUSABLE BUG (HIGH, self-inflicted, adversarial review caught it):** I added
`since_summary=$((since_summary + heartbeat_interval))` to the drive arm. Under
this script's `set -uo pipefail`, a NON-NUMERIC `GOLEM_HEARTBEAT_INTERVAL` (a
plausible typo like `15m`/`900s`) makes bash treat the alphabetic token as an
UNBOUND VARIABLE in `$(( ))` and **aborts the whole watch** (exit 1). The
pre-#489 loop only did `sleep "$heartbeat_interval"` (non-fatal). I had guarded
the *sibling* knob (`summary_due` validates its args) but left the one I newly
consumed in arithmetic exposed — classic "hardened X, introduced same hole in Y."
Fix = coerce at the source: `case "$heartbeat_interval" in '' | *[!0-9]*)
heartbeat_interval=60 ;; esac`. **Lesson: any NEW `$(( ))` use of an
env-sourced var under `set -u` is a crash vector; apply the numeric guard at the
assignment, and when you harden one knob grep for EVERY sibling that reaches
arithmetic.** Also fixed: startup `liveness_summary` fired even at interval=0
(contradicted "0 disables it") → new `summary_enabled()` gates the startup line too.

**Ship mechanics:** L1 pre-PR adversarial review ran ~35min (hit the 20min
checkpoint → operator chose extend to 40min ceiling; verdict via
`workflow-wall-timeout.sh`). Returned clean (0 blocking, 5 deferrable) — I fixed
all 5 anyway since 3 were real (the crash + 2 coverage gaps) and cheap. 48 tests
(was 45→48 after fixes). shellcheck SC2154 on reading a sourced tunable by name →
scoped `# shellcheck disable=SC2154`; SC2034 on a bare `VAR=x` before `source` →
`export VAR=x`. `.claude/memory/MEMORY.md` was pre-modified at session start
(unrelated) → excluded from the commit.
