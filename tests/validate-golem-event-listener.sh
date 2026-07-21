#!/usr/bin/env bash
# Coverage for the orchestrator-side event RECEIVER
# plugins/workflow/scripts/golem-event-listener.{py,sh} (issue #407) — the
# consumption half of the golem event bus (ADR-0001 Decision 3).
#
# The emitter (#406, golem-notify.sh) POSTs each classified event — a body
# BYTE-IDENTICAL to a feed.jsonl line — to every GOLEM_EVENT_SINKS endpoint. This
# receiver is one such endpoint: it appends each received POST into THIS
# orchestrator's feed.jsonl so the existing golem-gate-watch.sh --stream Monitor
# floor surfaces a container golem's gate without a shared filesystem. Because it
# writes the same feed the floor already reads, the acceptance criteria reduce to
# a handful of observable behaviours:
#
#   * AC1/AC3 — a POSTed gate/escalation event lands as a feed line that
#     golem-gate-watch.sh --once then surfaces IDENTICALLY to a locally-emitted
#     event (same golem-id attribution + classification), for a golem with no
#     shared filesystem (proven here by POSTing directly, no container needed).
#   * AC2 — the receiver is OPTIONAL: it binds a socket only when run; the .sh
#     shim FAILS LOUD (non-zero) when no python3>=3.11 is present rather than
#     silently no-op'ing.
#   * never-block / robustness — a malformed, oversized, non-object, or
#     wrong-method request is rejected without writing a feed line and WITHOUT
#     crashing the server (the next valid POST still succeeds).
#   * normalization — a missing `ts` is re-stamped, an absent `event` defaults to
#     `gate` (matching golem-notify.sh's fail-loud default), and the `golem-?`
#     orphan sentinel is ACKed but not appended.
#
# Runtime: the receiver is Python 3.11+ (no bash fallback), driven over HTTP with
# curl. Both are on PATH in CI; locally the suite SKIPS cleanly when either is
# absent (mirrors the sibling golem gates). Sandboxes are fresh `git init` repos
# under a module-level mktemp, with git's hook-exported env scrubbed so the
# listener resolves the feed under the SANDBOX (not the outer checkout) even when
# the suite runs from a pre-push hook — the same hardening validate-golem-notify.sh
# uses. Absolute /usr/bin/* paths per project convention; shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LISTENER_PY="$REPO_ROOT/plugins/workflow/scripts/golem-event-listener.py"
LISTENER_SH="$REPO_ROOT/plugins/workflow/scripts/golem-event-listener.sh"
GATE_WATCH="$REPO_ROOT/plugins/workflow/scripts/golem-gate-watch.sh"

REAL_BASH="$(command -v bash)"

# Git's hook-exported environment — scrub per invocation so each sandbox is
# hermetic even under a pre-push hook (see validate-golem-notify.sh).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# The listener + gate-watch resolve the feed under GOLEM_STATUS_DIR /
# GOLEM_WORKTREE_DIR; scrub any operator/worktree override so the fixed
# .worktrees/.status read-back path holds. GOLEM_EVENT_LISTEN_* are scrubbed so a
# stray override cannot change the bind we pass explicitly per case.
GOLEM_SCRUB=(GOLEM_STATUS_DIR GOLEM_WORKTREE_DIR
    GOLEM_EVENT_LISTEN_ADDR GOLEM_EVENT_LISTEN_PORT GOLEM_EVENT_MAX_BODY)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "golem-event-listener.sh receiver (#407)"

# --- Prerequisites ----------------------------------------------------------

python_unavailable() {
    command -v python3 >/dev/null 2>&1 &&
        python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
            2>/dev/null && return 1
    return 0
}
curl_unavailable() { ! command -v curl >/dev/null 2>&1; }

test_prereqs() {
    if python_unavailable; then
        skip_test "python3>=3.11 not available"
        return 0
    fi
    if curl_unavailable; then
        skip_test "curl not available"
        return 0
    fi
    assert_file_exists "$LISTENER_PY" "listener .py present"
    assert_file_exists "$LISTENER_SH" "listener .sh shim present"
}

# --- Sandbox + listener lifecycle -------------------------------------------

WORKDIR="$(/usr/bin/mktemp -d)"
# Track a started listener so the EXIT trap always reaps it.
LISTENER_PID=""
cleanup() {
    [ -n "$LISTENER_PID" ] && /bin/kill "$LISTENER_PID" 2>/dev/null || true
    /usr/bin/rm -rf "$WORKDIR"
}
trap cleanup EXIT

# new_sandbox <varname> — fresh `git init` repo with a .worktrees/.status/ dir.
# The internal var is deliberately NOT named `dir`: callers pass `dir` as the
# out-param name, and a same-named local here would shadow it (leaving the
# caller's `dir` unset under `set -u`).
new_sandbox() {
    local __out="$1" _newdir
    _newdir="$(/usr/bin/mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$_newdir" init -q 2>/dev/null || return 1
    /usr/bin/mkdir -p "$_newdir/.worktrees/.status"
    printf -v "$__out" '%s' "$_newdir"
}

# free_port — an ephemeral loopback port the OS hands out (bind :0, read it back,
# close). A tiny race between close and the listener's bind is acceptable for a
# test; the listener FAILS LOUD on a bind collision, which the caller detects.
free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# start_listener <sandbox> <port> — launch the listener in <sandbox> bound to
# 127.0.0.1:<port>, wait until /healthz answers (bounded), set LISTENER_PID.
# Returns non-zero if it never came up.
start_listener() {
    local dir="$1" port="$2" tries=0
    (
        cd "$dir" &&
            exec /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                HOME="$dir" \
                GOLEM_EVENT_LISTEN_ADDR=127.0.0.1 GOLEM_EVENT_LISTEN_PORT="$port" \
                python3 "$LISTENER_PY"
    ) >"$dir/listener.log" 2>&1 &
    LISTENER_PID=$!
    while [ "$tries" -lt 50 ]; do
        if curl -s -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null; then
            return 0
        fi
        # Bail early if the process already died (e.g. bind collision).
        /bin/kill -0 "$LISTENER_PID" 2>/dev/null || return 1
        /usr/bin/sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

stop_listener() {
    [ -n "$LISTENER_PID" ] && /bin/kill "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""
}

# post <port> <path> <body> — POST <body> to the listener; echo the HTTP status.
post() {
    local port="$1" path="$2" body="$3"
    curl -s -o /dev/null -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data-raw "$body" "http://127.0.0.1:$port$path" 2>/dev/null || echo "000"
}

feed_of() { /bin/cat "$1/.worktrees/.status/feed.jsonl" 2>/dev/null || true; }

# --- Tests ------------------------------------------------------------------

# AC1/AC3: a POSTed gate becomes a feed line that gate-watch --once surfaces.
# gate-watch's ghost-reaping filter (#464) only surfaces a golem with a live
# trace, so the sandbox carries a golem-5.json cache (the trace an orchestrator
# supervising a container golem holds). No `ts` in the POST ⇒ the listener stamps
# a fresh one, so it is inside the freshness window.
test_post_gate_surfaces_via_gatewatch() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir port code out
    new_sandbox dir
    /usr/bin/printf '{"issue":5,"golem":"golem-5"}\n' >"$dir/.worktrees/.status/golem-5.json"
    port="$(free_port)"
    if ! start_listener "$dir" "$port"; then
        _fail "listener did not start" "log: $(
            feed_of "$dir"
            /bin/cat "$dir/listener.log" 2>/dev/null
        )"
        return 1
    fi
    code="$(post "$port" "/" '{"golem":"golem-5","event":"gate","message":"Claude needs your permission to push"}')"
    assert_equals "204" "$code" "POST gate → 204"
    assert_file_contains "$dir/.worktrees/.status/feed.jsonl" '"golem":"golem-5"' \
        "feed line appended for golem-5"
    assert_file_contains "$dir/.worktrees/.status/feed.jsonl" '"event":"gate"' \
        "feed line carries the gate event kind"
    # Surface it through the UNCHANGED floor.
    out="$(cd "$dir" && /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV HOME="$dir" \
        GOLEM_STATUS_DIR=.worktrees/.status "$REAL_BASH" "$GATE_WATCH" --once 2>/dev/null || true)"
    assert_contains "$out" "golem-5" "gate-watch --once surfaces golem-5"
    assert_contains "$out" "Claude needs your permission to push" \
        "gate-watch --once surfaces the golem's message verbatim (AC3)"
    stop_listener
}

# An escalation POST keeps its distinct classification through the feed.
test_post_escalation_preserves_kind() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir port code
    new_sandbox dir
    port="$(free_port)"
    start_listener "$dir" "$port" || {
        _fail "listener did not start"
        return 1
    }
    code="$(post "$port" "/" '{"golem":"golem-7","event":"escalation","message":"ESCALATION: pick an approach [gate-1-a]"}')"
    assert_equals "204" "$code" "POST escalation → 204"
    assert_file_contains "$dir/.worktrees/.status/feed.jsonl" '"event":"escalation"' \
        "escalation kind preserved in the feed line"
    stop_listener
}

# Normalization: no `ts` re-stamped; absent `event` defaults to gate.
test_normalization_defaults() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir port line
    new_sandbox dir
    port="$(free_port)"
    start_listener "$dir" "$port" || {
        _fail "listener did not start"
        return 1
    }
    post "$port" "/" '{"golem":"golem-3","message":"no event, no ts"}' >/dev/null
    line="$(feed_of "$dir")"
    assert_contains "$line" '"event":"gate"' "absent event defaults to gate"
    assert_contains "$line" '"ts":"2' "absent ts is re-stamped (ISO-ish)"
    stop_listener
}

# The orphan sentinel golem-? is ACKed (204) but never appended (no attach
# target; the feed reader drops it anyway).
test_orphan_sentinel_not_appended() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir port code
    new_sandbox dir
    port="$(free_port)"
    start_listener "$dir" "$port" || {
        _fail "listener did not start"
        return 1
    }
    code="$(post "$port" "/" '{"golem":"golem-?","event":"gate","message":"x"}')"
    assert_equals "204" "$code" "orphan sentinel POST is ACKed (204)"
    assert_true "[ ! -s '$dir/.worktrees/.status/feed.jsonl' ]" \
        "orphan sentinel appends NO feed line"
    stop_listener
}

# Robustness: malformed / non-object / oversized / wrong-method are rejected
# without writing a feed line AND without crashing — a valid POST after each
# still succeeds (same server instance).
test_bad_requests_rejected_without_crash() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir port code
    new_sandbox dir
    /usr/bin/printf '{"issue":8,"golem":"golem-8"}\n' >"$dir/.worktrees/.status/golem-8.json"
    port="$(free_port)"
    start_listener "$dir" "$port" || {
        _fail "listener did not start"
        return 1
    }
    assert_equals "400" "$(post "$port" "/" 'not json')" "invalid JSON → 400"
    assert_equals "400" "$(post "$port" "/" '[1,2,3]')" "non-object JSON → 400"
    # Oversized: exceed GOLEM_EVENT_MAX_BODY (default 65536) → 413.
    local big
    big="$(python3 -c 'print("{\"golem\":\"golem-8\",\"message\":\"" + "z"*70000 + "\"}")')"
    assert_equals "413" "$(post "$port" "/" "$big")" "oversized body → 413"
    # Wrong method on POST-only path.
    assert_equals "404" "$(curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$port/nope" 2>/dev/null)" "unknown GET path → 404"
    # The server is still alive: a valid POST now succeeds and lands a line.
    assert_equals "204" "$(post "$port" "/" '{"golem":"golem-8","event":"gate","message":"still alive"}')" \
        "valid POST after bad ones still 204 (server did not crash)"
    assert_file_contains "$dir/.worktrees/.status/feed.jsonl" '"message":"still alive"' \
        "the recovery POST landed a feed line"
    stop_listener
}

# healthz liveness probe.
test_healthz() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir port out
    new_sandbox dir
    port="$(free_port)"
    start_listener "$dir" "$port" || {
        _fail "listener did not start"
        return 1
    }
    out="$(curl -s "http://127.0.0.1:$port/healthz" 2>/dev/null || true)"
    assert_contains "$out" "ok" "GET /healthz → ok"
    stop_listener
}

# The .sh shim FAILS LOUD (non-zero) when no python3>=3.11 is reachable — no
# silent no-op. Simulate "no python" with an empty PATH holding only bash/env.
test_shim_fails_loud_without_python() {
    local dir bindir rc out
    new_sandbox dir
    bindir="$dir/bin"
    /usr/bin/mkdir -p "$bindir"
    # Provide only the shell + a dirname/pwd the shim needs at startup, but NO
    # python3, so the version gate cannot be satisfied.
    for tool in bash env dirname pwd; do
        p="$(command -v "$tool" 2>/dev/null || true)"
        [ -n "$p" ] && /bin/ln -sf "$p" "$bindir/$tool"
    done
    rc=0
    # Unset BASH_ENV: on a devcontainer it points at /etc/bash_env, which sources
    # /etc/bashrc.d/*.sh (one of which can block on an auth check) and would hang
    # the reduced-PATH child — the repo-standard PATH-stub-test precaution.
    out="$(/usr/bin/env --unset=BASH_ENV PATH="$bindir" "$REAL_BASH" "$LISTENER_SH" 2>&1)" || rc=$?
    assert_true "[ '$rc' -ne 0 ]" "shim exits non-zero when python3>=3.11 absent"
    assert_contains "$out" "python3>=3.11" "shim message names the Python floor"
}

# --- Runner -----------------------------------------------------------------

run_test test_prereqs "prerequisites: python3>=3.11 + curl + files present"
run_test test_post_gate_surfaces_via_gatewatch "gate POST → feed → gate-watch --once surfaces it (AC1/AC3)"
run_test test_post_escalation_preserves_kind "escalation POST keeps its kind in the feed"
run_test test_normalization_defaults "normalization: absent ts re-stamped, absent event → gate"
run_test test_orphan_sentinel_not_appended "orphan golem-? ACKed but not appended"
run_test test_bad_requests_rejected_without_crash "bad/oversized/wrong-method rejected without crash"
run_test test_healthz "GET /healthz liveness probe"
run_test test_shim_fails_loud_without_python "shim fails loud when python3>=3.11 absent (no bash fallback)"

generate_report
