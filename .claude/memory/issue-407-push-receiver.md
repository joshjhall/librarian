---
name: issue-407-push-receiver
description: "#407 golem-event HTTP receiver: consumption half of the event bus; design + review fixes + sandbox socket-kill gotcha"
metadata: 
  node_type: memory
  type: project
  originSessionId: cb59df21-a3c9-47e0-b22f-1b29f5566d39
  modified: 2026-07-21T15:38:09.831Z
---

SHIPPED PR #476 (2026-07-21, L3): the consumption half of the golem event bus (ADR-0001 Decision 3), follow-up to [[issue-406-multi-sink-emitter]].

**Design (the elegant bit):** #406's emitter POSTs a body BYTE-IDENTICAL to a `feed.jsonl` line (`{ts,golem,event,message}`). So the receiver `golem-event-listener.py` just **appends each POST into the orchestrator's own feed.jsonl** — the EXISTING `golem-gate-watch.sh --stream` Monitor floor then surfaces it with zero new classification/attribution code. AC1/AC2/AC3 fall out for free. Python 3.11+ `ThreadingHTTPServer` + bash-3.2 version-gate shim (`golem-event-listener.sh`) that FAILS LOUD (no bash fallback for an HTTP server) — mirrors autonomy-resolve.sh shim.

**Review caught 3 blocking (all real, all fixed in-PR):**

1. CRITICAL: unvalidated client `ts` → `golem-gate-watch.sh`'s `jq fromdateiso8601` ABORTS the WHOLE pipeline on any unparsable ts (swallowed by 2>/dev/null) → silently blanks the BLOCKED floor for EVERY golem in the tail-200 window. Reopened the #24 class the moment an external ts was accepted over HTTP. Fix = `_valid_ts()` strict `%Y-%m-%dT%H:%M:%SZ` check, else re-stamp. **Lesson: any NEW external writer of a field the readers parse must validate that field's shape — the trusted-local-only assumption breaks.**
2. HIGH: tests exec'd `python3` directly, never the `.sh` shim → shim happy path (config.sh source, exec, env passthrough) untested. Fix = launch via `$LISTENER_SH`.
3. HIGH scope-drift: ADR "LANDED" overstated AC1 for container golems (transport is unlanded containers#735/#743). Fix = soften to "LANDED librarian-side; container end-to-end blocked on containers#735/#743". Receiver is standalone-testable; a real container golem can't reach it yet.

Deferrables → #478 (slow-loris timeout, ingress-auth, 5 test-gaps, doc rows).

**ENV GOTCHA (cost me many retries):** this interactive session's sandbox KILLS any process that binds a loopback TCP socket (exit 144 / SIGTERM) — started mid-session, not present at start. So `validate-golem-event-listener.sh` (binds a listener) and even a bare `python3 -c 'socket.bind(("127.0.0.1",0))'` return 144 in-session. The suite is FINE: it passes in the **pre-push `quality-gates` hook** (runs full run-all.sh in a socket-capable context — "All test stages passed", 100s). Lesson: for socket-binding tests, trust the pre-push hook as the behavioral gate; don't burn cycles re-running in-session. Related but distinct from [[devcontainer-bash-env-path-reset]] (the shim fail-loud test ALSO needed BASH_ENV unset).

PARKED for human merge (L3 self-authored, auto-mode blocks self-merge per [[auto-mode-blocks-self-merge]]).
