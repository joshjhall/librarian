---
name: broker-inbox-gate-resolution
description: "#227 golem-inbox.sh reverse channel — relays escalation/dead-end decisions back down; data-only, plan-approval excluded by #29"
metadata: 
  node_type: memory
  type: project
  originSessionId: bfe4d94a-dfa2-4553-bd60-78b7236bc16d
  modified: 2026-07-19T00:46:18.808Z
---

Issue #227 (slice 1, branch `feature/issue-227/broker-inbox`) added
`golem-inbox.sh` — the REVERSE of the push feed. The feed
(`golem-notify.sh` → `feed.jsonl`) is golem→orchestrator (up); the inbox is
orchestrator→golem (down). An operator supervising N golems answers each parked
escalation/dead-end from ONE central `AskUserQuestion` and relays the decision
back into the originating golem via a per-golem `inbox-<golem>.jsonl` (sibling of
feed.jsonl under `GOLEM_STATUS_DIR`), which the golem polls with `consume` — no
per-golem `golem-attach` required. Subcommands: `gateid` / `answer` / `consume`
/ `peek`.

**Correlation = gate-id embedded in the feed MESSAGE, no schema change.** The
golem mints `gate-<epoch>-<rand4hex>` (`golem-inbox.sh gateid`), embeds
`[$GATE_ID]` in its `ESCALATION:`/`DEAD-END:` message + issue comment; the
orchestrator greps it back out (`grep -oE 'gate-[0-9]+-[0-9a-z]+'`). Chosen over
a 5th feed field to keep the frozen, dependency-free `golem-notify.sh` +
`feed_snapshot` + every feed test untouched (diverges from the issue's speculative
Affected-Files note — called out in the PR). Two-layer attribution (filename
keyed by golem-id + in-record gate filter) so golem-N's answer can't reach golem-M.

**Data-only invariant — plan-approval is DELIBERATELY excluded (the #29 spike
conclusion).** The inbox carries decision DATA and must NEVER resolve an
auto-mode gate. Plan-approval IS an auto-mode resolution and is already brokered
compliantly by [[autonomy-vs-plangate-flags]]'s cousin #281 (central present +
human-authorized directed `tmux send-keys`). Routing it through the inbox would
turn "human pre-authorized launches" into "agent resolves auto-mode gates" — the
`[Create Unsafe Agents]` boundary. So the spike's honest outcome: the compliant
design already exists, inbox stays out of it.

**wait-indefinitely under the Bash 600s tool ceiling:** `consume` is a
bounded-blocking read (≤`GOLEM_INBOX_WAIT`=300s, poll `GOLEM_INBOX_POLL`=3s);
on no answer prints `NO-DECISION` (NEVER a default) and the SKILL re-invokes
forever. L4 escalation auto-resolves → never consumes; dead-end at every level
(incl L4) brokers like an escalation. Golem-side loop uses `$GOLEM_ID` (stamped
at launch), not a hand-substituted `golem-{N}`.

**Two hardening bugs the code-review caught (both fixed + regression-tested):**

1. **Octal hang** — a leading-zero tunable (`GOLEM_INBOX_POLL=08`) passes the
   all-digit `case *[!0-9]*` guard but `$(( elapsed + poll_s ))` reads it as
   OCTAL (8/9 invalid → arithmetic errors under `set -uo pipefail` no-`-e` →
   `elapsed` never advances → hang past the ceiling). Fix = normalize both
   tunables through `$(( 10#$v ))` after the digit check.
2. **jq reader truncation** — `jq '…' file` parses the file as one DOCUMENT and
   aborts on the FIRST malformed line (a torn append), silently dropping every
   record after it (would replay a stale decision past its `consumed` marker or
   hide a corrected answer). Fix = per-line `jq -rc -Rn '[ inputs | (fromjson? //
   empty) | … ]'` so one bad line is skipped, not fatal (applied to `consume`
   reader + `peek`). The no-jq bash scanner was already resilient.

Tests: `tests/validate-golem-inbox.sh` wired into run-all.sh. See
[[two-runtime-model]] (bash script reaches host fs, unlike workflow.js) and
[[usr-bin-hardcoding-golem-scripts]] (docs use `command grep`, not `/usr/bin/grep`).

**#395 (the read-side follow-up) — the `state` subcommand + two review-caught
bugs, one LATENT in #227.** #395 added `golem-inbox.sh state <golem> <gate-id>`
(prints `awaiting|answered|consumed` via a last-wins event fold) and had
`golem-status.sh` annotate each BLOCKED escalation/dead-end line with
`[inbox: <state>]`. Its code review surfaced:

1. **jq scalar-line crash (LATENT in #227's `inbox_latest_answer_jq` + `peek`,
   not just the new `state`).** `(fromjson? // empty)` only skips UNPARSABLE
   lines; a valid NON-OBJECT scalar (`42`/`true`/`[]`) then aborts the whole
   `reduce` when `.golem` indexes it ("cannot index number") — silently masking
   the true state AND breaking `consume` (a live answer became unreachable). Fix
   = add `select(type == "object")` after every `fromjson?` (all three jq call
   sites). The no-jq substring scanner was always immune, so the two paths had
   diverged on real input.
2. **Unanchored gate-id regex in golem-status.** `grep -oE 'gate-[0-9]+-[0-9a-z]+'`
   over the whole free-text message false-positived a routine gate whose command
   text held a gate-shaped substring (`fix/gate-123-x`) and mis-picked a stray
   earlier mention before the real bracketed id. Fix = anchor to the BRACKETED
   `\[gate-…\]` token the escalation protocol actually emits, then strip
   brackets. Both fixes regression-tested (scalar-resilience + bracketed-anchor +
   routine-gate-substring cases).
