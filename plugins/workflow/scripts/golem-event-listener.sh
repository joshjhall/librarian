#!/usr/bin/env bash
# golem-event-listener.sh — version-gate entrypoint for the golem event receiver.
#
# The consumption half of the golem event bus (#407, ADR-0001 Decision 3). The
# real receiver is the Python 3.11+ implementation golem-event-listener.py: an
# HTTP server that accepts the events #406's golem-notify.sh POSTs to a
# GOLEM_EVENT_SINKS endpoint and appends each into the orchestrator's own
# feed.jsonl, so the existing golem-gate-watch.sh --stream Monitor floor surfaces
# a container golem's gate the moment it emits — no shared filesystem required.
# See golem-event-listener.py for the full design and trust-boundary notes.
#
# This shim exists ONLY to select the runtime, mirroring autonomy-resolve.sh: an
# HTTP server has no clean bash-3.2 implementation, so — unlike the patterns.sh
# pre-scan family, which carries a real bash FALLBACK body — this shim FAILS LOUD
# (non-zero exit + an actionable message naming the Python floor) when no
# python3>=3.11 is present, rather than silently no-op'ing a receiver that would
# then drop every event. That fail-loud stance is the runtime policy for a tool
# with no portable fallback (CLAUDE.md § Key conventions).
#
# It sources config.sh so an operator's GOLEM_STATUS_DIR / GOLEM_WORKTREE_DIR
# override (and the GOLEM_EVENT_LISTEN_* defaults) reach the Python process via
# the environment, keeping the emitter, the readers, and this listener resolving
# the feed one consistent way.
#
# Usage:
#   golem-event-listener.sh            # bind + serve until SIGINT/SIGTERM
#
# Config (env; see config.sh): GOLEM_EVENT_LISTEN_ADDR (default 127.0.0.1),
# GOLEM_EVENT_LISTEN_PORT (default 8787), GOLEM_EVENT_MAX_BODY (default 65536),
# GOLEM_STATUS_DIR / GOLEM_WORKTREE_DIR (feed location).
#
# Exit codes: propagates the Python process's exit (0 clean shutdown, 1 bind
# failure, 2 bad config); 3 when no python3>=3.11 is available (fail loud).
# bash-3.2 clean (no associative arrays / namerefs / case-conversion).
set -euo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

PY="$SCRIPT_DIR/golem-event-listener.py"
if [ ! -f "$PY" ]; then
    command echo "golem-event-listener: missing $PY" >&2
    exit 3
fi

# Require python3>=3.11 — the receiver's sole runtime. No bash fallback body: an
# HTTP server is not portably expressible in bash 3.2, so refuse loudly rather
# than pretend to listen. Selection order mirrors autonomy-resolve.sh's shim.
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$PY" "$@"
fi

command echo "golem-event-listener: requires python3>=3.11 (the HTTP receiver has \
no bash fallback); install a newer python3 or run the listener on a host that \
has one" >&2
exit 3
