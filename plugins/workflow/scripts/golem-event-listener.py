#!/usr/bin/env python3
"""golem-event-listener — orchestrator-side receiver for golem gate events (#407).

The consumption half of the golem event bus (ADR-0001 Decision 3, the additive
approach (b)). The emitter half (#406, golem-notify.sh) fans each classified
event to `feed.jsonl` ALWAYS and, in addition, POSTs the SAME JSON line to every
`GOLEM_EVENT_SINKS` HTTP endpoint. This script is one such endpoint: it receives
those POSTs and appends each into the orchestrator's own `feed.jsonl`, so the
existing `Monitor(golem-gate-watch.sh --stream)` floor surfaces them IDENTICALLY
to a locally-emitted event — for golems that do NOT share the orchestrator's
filesystem (container golems), whose feed is otherwise trapped inside the
container (the transport gap tracked in containers#735).

The design turns on one fact: the #406 POST body is BYTE-IDENTICAL to a
`feed.jsonl` line — `{ts, golem, event, message}` (see golem-notify.sh, which
builds the line ONCE and sends the same string to every sink). So the receiver
needs NO new classification, golem-id attribution, or surfacing logic; it
appends the received line into the feed and the unchanged floor does the rest.
That is why the acceptance criteria fall out for free:

  * receive-and-surface for BOTH golem types — the feed floor is TTY-free and
    already covers headless/container golems (AC1);
  * OPTIONAL / additive — this binds a socket only when the operator runs it;
    absent, the feed + Monitor floor stands unchanged and worktree golems never
    need it (AC2);
  * surfaces IDENTICALLY to the feed channel — because it writes the same feed
    the channel already reads, gate/escalation/dead-end classification and
    golem-id attribution are preserved verbatim (AC3);
  * the GitHub PR/issue-label poll is untouched — this governs only the
    live-decision-point signal, never external state (AC4).

REPO BOUNDARY (ADR Decision 5): this is the librarian-side RECEIVER. The
container->host transport that carries a container golem's POST out to this
listener (mount/forward `.worktrees/.status`, build-wire the container HTTP sink)
is a cross-repo follow-up owned by containers#735 — NOT part of this change. The
listener is fully testable standalone by POSTing to it directly.

TRUST BOUNDARY: like the emitter's `GOLEM_EVENT_SINKS` (see config.sh), this is a
best-effort, operator-controlled component. It binds LOOPBACK (127.0.0.1) by
default, so it is not reachable off-host unless the operator deliberately widens
`GOLEM_EVENT_LISTEN_ADDR`. The received `message` is treated as opaque DATA: it
is only ever re-serialized into the feed as a JSON string (never interpreted as
an instruction, a path, or a shell word) and the body is bounded
(`GOLEM_EVENT_MAX_BODY`), so a malformed or oversized POST is rejected without
writing a feed line and without crashing the server. Host allow-listing beyond
the loopback default, TLS, and request signing remain deliberate NON-goals of
this best-effort receiver, exactly as the #406 emitter documented them as the
receiver's concern.

Runtime: Python 3.11+ primary (this file), reached via the bash-3.2-clean
version-gate shim golem-event-listener.sh — an HTTP server has no clean bash
fallback, so the shim FAILS LOUD when no python3>=3.11 is present rather than
silently no-op'ing. See CLAUDE.md § Key conventions (runtime policy).

Config (env, defaults mirror config.sh):
  GOLEM_EVENT_LISTEN_ADDR   bind address           (default 127.0.0.1)
  GOLEM_EVENT_LISTEN_PORT   bind port              (default 8787)
  GOLEM_EVENT_MAX_BODY      max request body bytes (default 65536)
  GOLEM_STATUS_DIR          status dir holding feed.jsonl (repo-root-relative;
                            default .worktrees/.status — same as the readers)
  GOLEM_WORKTREE_DIR        worktree dir (default .worktrees; only used to derive
                            the GOLEM_STATUS_DIR default)

Endpoints:
  POST /            accept one event; 204 on append, 4xx on a bad body.
  GET  /healthz     liveness probe; 200 "ok".

Exit: SIGINT/SIGTERM shut the server down cleanly (exit 0). A bind failure
(port in use, bad address) FAILS LOUD on stderr with a non-zero exit.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The BLOCKED set the feed reader recognizes; every other kind (idle, resolved,
# reaped) is not a block. We do NOT re-classify a received event — the emitter
# already classified it — but an ABSENT event defaults to "gate", matching
# golem-notify.sh's fail-loud default (surface an unknown event rather than
# silently drop it as idle).
_DEFAULT_EVENT = "gate"
_DEFAULT_MESSAGE = "awaiting decision"
# The orphan sentinel golem-notify.sh stamps when it cannot resolve a golem id
# (a Notification from a non-golem session). It is never actionable — no
# golem-attach target — and the feed reader drops it anyway, so we do not append
# it (avoids feed noise) while still ACKing the POST so a client never error-loops.
_ORPHAN_GOLEM = "golem-?"

# Serialize feed appends across handler threads (ThreadingHTTPServer runs each
# request on its own thread). A single line write() in append mode is effectively
# atomic on POSIX for a bounded line, but the lock makes it unconditional.
_feed_lock = threading.Lock()


def _iso_now() -> str:
    """UTC timestamp in the same shape golem-notify.sh stamps (date -u +%FT%TZ)."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def resolve_feed_path() -> str:
    """Resolve <repo-root>/<GOLEM_STATUS_DIR>/feed.jsonl the same way the readers do.

    The status dir is repo-root-relative (config.sh default .worktrees/.status);
    the root is the MAIN checkout, found from git's common dir whose parent is the
    main checkout — identical to golem-notify.sh / repo_root(), so an operator who
    overrides GOLEM_STATUS_DIR moves the emitter, the readers, AND this listener
    together. Resolved ONCE at startup: the listener runs in a fixed cwd.

    Falls back to a cwd-relative path when not inside a git repo, so the listener
    still starts (and a test can point it at a scratch dir) rather than aborting.
    """
    worktree_dir = os.environ.get("GOLEM_WORKTREE_DIR", "").strip() or ".worktrees"
    status_dir = (
        os.environ.get("GOLEM_STATUS_DIR", "").strip() or f"{worktree_dir}/.status"
    )

    root = ""
    try:
        common_dir = subprocess.run(
            ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        ).stdout.strip()
        if common_dir:
            root = os.path.dirname(common_dir)
    except (OSError, subprocess.SubprocessError):
        root = ""

    if os.path.isabs(status_dir):
        base = status_dir
    elif root:
        base = os.path.join(root, status_dir)
    else:
        base = os.path.abspath(status_dir)
    return os.path.join(base, "feed.jsonl")


def normalize_event(payload: dict) -> dict | None:
    """Normalize a received payload into a `{ts, golem, event, message}` feed line.

    Trusts the emitter's classification (does NOT re-derive `event` from the
    message) but supplies golem-notify.sh's defaults for any missing field so the
    appended line is always a well-formed feed record. Returns None for a payload
    that must not be appended (no resolvable golem, or the orphan sentinel).
    """
    golem = str(payload.get("golem", "")).strip()
    if not golem or golem == _ORPHAN_GOLEM:
        return None
    event = str(payload.get("event", "")).strip() or _DEFAULT_EVENT
    message = payload.get("message", "")
    message = str(message) if message != "" else _DEFAULT_MESSAGE
    ts = str(payload.get("ts", "")).strip() or _iso_now()
    return {"ts": ts, "golem": golem, "event": event, "message": message}


def append_feed_line(feed_path: str, record: dict) -> None:
    """Append one normalized JSON record to feed.jsonl (one object per line).

    Creates the status dir if absent. Holds the module lock so concurrent handler
    threads never interleave a partial line.
    """
    line = json.dumps(record, separators=(",", ":"), ensure_ascii=False)
    with _feed_lock:
        os.makedirs(os.path.dirname(feed_path), exist_ok=True)
        with open(feed_path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


class EventHandler(BaseHTTPRequestHandler):
    """Receive golem event POSTs and append them to the feed. Best-effort: a bad
    request is answered with a 4xx and never propagates as a crash."""

    # Set by make_server on the server instance; read off self.server here.
    server_version = "golem-event-listener/1.0"

    def _feed_path(self) -> str:
        return self.server.feed_path  # type: ignore[attr-defined]

    def _max_body(self) -> int:
        return self.server.max_body  # type: ignore[attr-defined]

    def _reply(self, code: int, body: str = "") -> None:
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler contract)
        if self.path.rstrip("/") in ("", "/healthz"):
            self._reply(200, "ok\n")
        else:
            self._reply(404, "not found\n")

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler contract)
        # Bound the body: require a Content-Length, reject an oversized or absent
        # one, so a slow/huge POST can never exhaust memory or wedge the receiver.
        raw_len = self.headers.get("Content-Length")
        if raw_len is None:
            self._reply(411, "length required\n")
            return
        try:
            length = int(raw_len)
        except ValueError:
            self._reply(400, "bad content-length\n")
            return
        if length < 0:
            self._reply(400, "bad content-length\n")
            return
        if length > self._max_body():
            self._reply(413, "payload too large\n")
            return

        try:
            body = self.rfile.read(length)
        except OSError:
            # Client vanished mid-body — nothing to record, do not crash.
            return

        try:
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._reply(400, "invalid json\n")
            return
        if not isinstance(payload, dict):
            self._reply(400, "expected a json object\n")
            return

        record = normalize_event(payload)
        if record is None:
            # A well-formed but non-actionable event (no golem / orphan sentinel):
            # ACK so the client does not error-loop, but write nothing.
            self._reply(204)
            return

        try:
            append_feed_line(self._feed_path(), record)
        except OSError as exc:
            # A feed the receiver cannot write is a server-side fault, not a bad
            # request — report it, but never crash the server.
            self._reply(500, f"feed write failed: {exc}\n")
            return
        self._reply(204)

    def log_message(self, fmt: str, *args) -> None:  # noqa: A002 (stdlib name)
        # Keep the receiver quiet: gates are surfaced by the gate-watch Monitor
        # reading the feed, NOT by this process's stdout. Per-request noise on
        # stderr only when explicitly asked, so an armed listener does not spam.
        if os.environ.get("GOLEM_EVENT_LISTEN_VERBOSE", "").strip() in ("1", "true"):
            sys.stderr.write("golem-event-listener: " + (fmt % args) + "\n")


def make_server(
    addr: str, port: int, feed_path: str, max_body: int
) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((addr, port), EventHandler)
    # Attach config to the server so handler instances (created per request) read
    # it without globals.
    httpd.feed_path = feed_path  # type: ignore[attr-defined]
    httpd.max_body = max_body  # type: ignore[attr-defined]
    return httpd


def main(argv: list[str]) -> int:
    addr = os.environ.get("GOLEM_EVENT_LISTEN_ADDR", "").strip() or "127.0.0.1"
    port_raw = os.environ.get("GOLEM_EVENT_LISTEN_PORT", "").strip() or "8787"
    max_body_raw = os.environ.get("GOLEM_EVENT_MAX_BODY", "").strip() or "65536"

    try:
        port = int(port_raw)
    except ValueError:
        sys.stderr.write(
            f"golem-event-listener: GOLEM_EVENT_LISTEN_PORT must be an integer, "
            f"got {port_raw!r}\n"
        )
        return 2
    try:
        max_body = int(max_body_raw)
    except ValueError:
        sys.stderr.write(
            f"golem-event-listener: GOLEM_EVENT_MAX_BODY must be an integer, "
            f"got {max_body_raw!r}\n"
        )
        return 2

    feed_path = resolve_feed_path()

    try:
        httpd = make_server(addr, port, feed_path, max_body)
    except OSError as exc:
        # Fail loud: a bind failure (port in use, bad address) is an actionable
        # startup error, not something to swallow.
        sys.stderr.write(f"golem-event-listener: cannot bind {addr}:{port} — {exc}\n")
        return 1

    # Clean shutdown on SIGTERM/SIGINT. serve_forever() blocks in the main thread,
    # and server.shutdown() must be called from a DIFFERENT thread, so the signal
    # handler raises KeyboardInterrupt (which serve_forever surfaces) and the
    # finally clause closes the socket.
    def _raise_interrupt(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, _raise_interrupt)

    bound_host, bound_port = httpd.socket.getsockname()[:2]
    sys.stderr.write(
        f"golem-event-listener: listening on {bound_host}:{bound_port} "
        f"→ {feed_path} (max body {max_body} bytes)\n"
    )
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
