---
name: issue-406-multi-sink-emitter
description: "SHIPPED PR #468 — golem-notify.sh multi-sink GOLEM_EVENT_SINKS fan-out (ADR-0001 spine item 2)"
metadata: 
  node_type: memory
  type: project
  originSessionId: b5836d04-7414-4c51-9f1b-8ae1719f1769
  modified: 2026-07-21T14:22:31.250Z
---

SHIPPED + MERGED PR #468 (2026-07-21, L3, origin/main `d474d85`, #406 auto-closed).
Emitter half of the #343 event bus (ADR-0001 Decision 2; dep #405 already merged).

**What:** `golem-notify.sh` builds the classified `{ts,golem,event,message}` line
ONCE, then fans it: `feed.jsonl` always + one bounded/backgrounded `curl` POST per
http(s) URL in `GOLEM_EVENT_SINKS` (space/comma list). `GOLEM_EVENT_SINK_TIMEOUT`
default 2s. Empty/unset ⇒ no curl spawned, byte-for-byte unchanged (AC2). mkdir
non-fatal (`|| exit 0`→`|| true`) so a hung feed dir doesn't skip the HTTP fan;
empty-`line` guard skips both sinks (no blank feed line). New knobs
documented/defaulted/exported in config.sh + README + a real drift-guard test.

**Adversarial review (0 blocking, 8 deferrable) — I FIXED them in-PR rather than
filing follow-ups** (in-context, cheap, high-certainty, my own code): the biggest
was a FALSE drift-guard claim I wrote (comment said the #424 test covered the two
new sink vars; it didn't) — flagged HIGH by 3 independent dimensions. Made it true
via `test_event_sink_defaults_match_config_sh` (greps the hook's inlined `:=`
lines, evals in a scrubbed subshell, asserts == config.sh). Also added curl-absent

+ unwritable-feed branch tests, README rows, and documented GOLEM_EVENT_SINKS as
trusted-operator input (SSRF/host-allowlist/https/signing are NON-goals scoped to
receiver #407). 30/30 golem-notify tests.

**BIG PROCESS NEAR-MISS** — see [[edits-landed-in-main-not-worktree]]: I used
main-checkout absolute paths from a worktree session, so ALL edits landed in the
MAIN checkout (on STALE main lacking #464's `reaped`); worktree git-status stayed
clean and I only caught it at ship time. Recovered by restoring main's 3 files +
re-applying fresh in the worktree on the correct base. Verify base blob hashes
before copying files between trees.

**Out of scope (ADR boundary):** orchestrator receiver #407, container transport
containers#743. Contributes to #343, not Closes. See [[librarian-runs-outside-containers]].
