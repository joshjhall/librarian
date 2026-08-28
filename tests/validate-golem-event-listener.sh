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

# free_port / with_free_port — ephemeral port allocation with retry (#780). This
# suite is an ENTRY POINT, so it sources the helper itself.
# shellcheck source=tests/lib/free-port.sh
source "$SCRIPT_DIR/lib/free-port.sh"

# Keep the real allocator under a second name so the contention test below can
# shadow free_port and still delegate to it for the second, genuinely-free port.
eval "real_free_port() $(declare -f free_port | command sed '1d')"

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

WORKDIR="$(command mktemp -d)"
# Track a started listener so the EXIT trap always reaps it.
LISTENER_PID=""
cleanup() {
    [ -n "$LISTENER_PID" ] && command kill "$LISTENER_PID" 2>/dev/null || true
    command rm -rf "$WORKDIR"
}
trap cleanup EXIT

# new_sandbox <varname> — fresh `git init` repo with a .worktrees/.status/ dir.
# The internal var is deliberately NOT named `dir`: callers pass `dir` as the
# out-param name, and a same-named local here would shadow it (leaving the
# caller's `dir` unset under `set -u`).
new_sandbox() {
    local __out="$1" _newdir
    _newdir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$_newdir" init -q 2>/dev/null || return 1
    command mkdir -p "$_newdir/.worktrees/.status"
    printf -v "$__out" '%s' "$_newdir"
}

# free_port lives in tests/lib/free-port.sh (#780) — sourced above. Callers use
# `with_free_port "$PORT_ATTEMPTS" start_listener "$dir"`, which re-allocates and
# re-attempts when the listener loses the bind-0-then-rebind race. The listener
# FAILS LOUD on a bind collision, which is what makes start_listener a correct
# retry predicate.

# _port_attempts_msg — the exhausted-retry diagnostic, with the attempt count
# INTERPOLATED from PORT_ATTEMPTS rather than restated (#825 item 2). Seven
# call sites print it; a literal in any of them would keep saying "2" after the count
# was raised, turning "a broken listener" into a misreported diagnosis.
_port_attempts_msg() {
    command printf 'listener did not start after %s port attempts' "$PORT_ATTEMPTS"
}

# start_listener <sandbox> <port> — launch the listener in <sandbox> bound to
# 127.0.0.1:<port>, wait until /healthz answers (bounded), set LISTENER_PID.
# Returns non-zero if it never came up.
#
# Launches via the .sh SHIM ($LISTENER_SH), not python3 directly, so every
# behavioral test also exercises the shim's success path — it sources config.sh,
# resolves SCRIPT_DIR, passes the version gate, and `exec`s python3 (exec replaces
# the shell in place, so $! still tracks the live server). A test that talked to
# the Python file directly would leave the shim's happy path uncovered; the
# separate fail-loud test only drives its no-python3 branch. BASH_ENV is unset so
# a devcontainer's /etc/bash_env sourcing cannot perturb the shim's own bash.
start_listener() {
    local dir="$1" port="$2" tries=0
    (
        cd "$dir" &&
            exec /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                HOME="$dir" \
                GOLEM_EVENT_LISTEN_ADDR=127.0.0.1 GOLEM_EVENT_LISTEN_PORT="$port" \
                "$REAL_BASH" "$LISTENER_SH"
    ) >"$dir/listener.log" 2>&1 &
    LISTENER_PID=$!
    while [ "$tries" -lt 50 ]; do
        # --max-time is LOAD-BEARING, not defensive tidiness. A port can be held
        # by a socket that listen()s but never replies — which is exactly what
        # the #780 contention fixture creates, and what a real racing process
        # may be. TCP connect then SUCCEEDS and curl blocks forever on a response
        # that never comes, so an unbounded curl turns this bounded poll into an
        # infinite one and start_listener never returns. Observed in CI: the job
        # hung after this suite and was cancelled at 15m with orphan curl/python3
        # processes. Reproduced outside the suite before fixing.
        #
        # The readiness check also requires the "ok" BODY, not merely a
        # successful curl. Whoever holds a contended port may be a listening
        # socket that is not this listener, and treating "something answered" as
        # "our listener is up" would return success for a port we never got —
        # the retry would then never fire and the test would talk to a stranger.
        # (The listener replies "ok\n"; `$(...)` strips the trailing newline.)
        case "$(curl -s --max-time 2 "http://127.0.0.1:$port/healthz" 2>/dev/null)" in
            *ok*) return 0 ;;
        esac
        # Bail early if the process already died (e.g. bind collision).
        command kill -0 "$LISTENER_PID" 2>/dev/null || {
            _reap_failed_listener
            return 1
        }
        command sleep 0.1
        tries=$((tries + 1))
    done
    _reap_failed_listener
    return 1
}

# _reap_failed_listener — clear a FAILED start so a with_free_port retry begins
# clean. Two things must happen, and neither is optional under retry:
#
#   * `wait` the pid, so the dead child is reaped rather than left a zombie for
#     the rest of the suite (a one-shot start could leave it to the EXIT trap;
#     a retry loop cannot, because it will start another one immediately);
#   * clear LISTENER_PID, so the EXIT trap and the next stop_listener cannot
#     signal a stale pid — which, after enough pid churn, is a signal aimed at
#     whatever process inherited that number.
#
# A never-came-up listener may still be ALIVE but wedged (the readiness poll
# simply timed out), so kill before waiting; a bind collision has already exited
# and the kill is an absorbed no-op.
#
# THE WAIT IS BOUNDED, for the reason the sibling shutdown in
# tests/python-corpus/90-workflow-tool-drivers.sh already states: a bare `wait`
# blocks forever if the SIGTERM handler ever stops firing (a future change
# swallowing the signal, a process wedged in a syscall). That risk is HIGHER
# here, not lower — this gate runs on every CI invocation of tests/run-all.sh,
# whereas the coverage driver is an optional reporting step — and the wedged
# call site is exactly the one this function exists to serve. An unbounded wait
# would turn a diagnosable failure into a whole-suite hang with no attribution.
# SIGKILL is the last resort; unlike the coverage driver there is no coverage
# data to lose by using it.
_reap_failed_listener() {
    [ -n "$LISTENER_PID" ] || return 0
    local waited=0
    command kill "$LISTENER_PID" 2>/dev/null || true
    while [ "$waited" -lt 50 ]; do
        command kill -0 "$LISTENER_PID" 2>/dev/null || break
        command sleep 0.1
        waited=$((waited + 1))
    done
    if command kill -0 "$LISTENER_PID" 2>/dev/null; then
        command printf 'listener %s ignored SIGTERM after 5s; killing\n' \
            "$LISTENER_PID" >&2
        command kill -KILL "$LISTENER_PID" 2>/dev/null || true
    fi
    wait "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""
}

stop_listener() {
    [ -n "$LISTENER_PID" ] && command kill "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""
}

# post <port> <path> <body> — POST <body> to the listener; echo the HTTP status.
post() {
    local port="$1" path="$2" body="$3"
    curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data-raw "$body" "http://127.0.0.1:$port$path" 2>/dev/null || echo "000"
}

feed_of() { command cat "$1/.worktrees/.status/feed.jsonl" 2>/dev/null || true; }

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
    command printf '{"issue":5,"golem":"golem-5"}\n' >"$dir/.worktrees/.status/golem-5.json"
    if ! with_free_port "$PORT_ATTEMPTS" start_listener "$dir"; then
        _fail "$(_port_attempts_msg)" "log: $(
            feed_of "$dir"
            command cat "$dir/listener.log" 2>/dev/null
        )"
        return 1
    fi
    port="$FREE_PORT"
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
    with_free_port "$PORT_ATTEMPTS" start_listener "$dir" || {
        _fail "$(_port_attempts_msg)"
        return 1
    }
    port="$FREE_PORT"
    code="$(post "$port" "/" '{"golem":"golem-7","event":"escalation","message":"ESCALATION: pick an approach [gate-1-a]"}')"
    assert_equals "204" "$code" "POST escalation → 204"
    assert_file_contains "$dir/.worktrees/.status/feed.jsonl" '"event":"escalation"' \
        "escalation kind preserved in the feed line"
    stop_listener
}

# Normalization: no `ts` re-stamped; absent `event` defaults to gate; a JSON
# `null` message falls back to the default (not the literal "None").
test_normalization_defaults() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir port line
    new_sandbox dir
    with_free_port "$PORT_ATTEMPTS" start_listener "$dir" || {
        _fail "$(_port_attempts_msg)"
        return 1
    }
    port="$FREE_PORT"
    post "$port" "/" '{"golem":"golem-3","message":"no event, no ts"}' >/dev/null
    line="$(feed_of "$dir")"
    assert_contains "$line" '"event":"gate"' "absent event defaults to gate"
    assert_contains "$line" '"ts":"2' "absent ts is re-stamped (ISO-ish)"
    # A JSON null message must NOT become the literal string "None".
    post "$port" "/" '{"golem":"golem-4","event":"gate","message":null}' >/dev/null
    line="$(feed_of "$dir")"
    assert_contains "$line" 'awaiting decision' "null message falls back to default"
    assert_not_contains "$line" '"message":"None"' "null message is not the literal None"
    stop_listener
}

# CRITICAL regression (correctness#2): a client-supplied malformed `ts` must NOT
# blank the whole BLOCKED floor. golem-gate-watch.sh's jq `fromdateiso8601` aborts
# the entire pipeline on any unparsable ts (swallowed by 2>/dev/null), silently
# dropping EVERY golem in the tail-200 window — not just the offending line. The
# listener guards against this by re-stamping any ts that is not the exact
# `%Y-%m-%dT%H:%M:%SZ` shape. This test POSTs a malformed-ts gate for one golem
# and a well-formed gate for another, then asserts gate-watch --once still
# surfaces BOTH — the well-formed golem's real gate must not vanish.
test_malformed_ts_does_not_blank_floor() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir port out
    new_sandbox dir
    command printf '{"issue":1,"golem":"golem-1"}\n' >"$dir/.worktrees/.status/golem-1.json"
    command printf '{"issue":2,"golem":"golem-2"}\n' >"$dir/.worktrees/.status/golem-2.json"
    with_free_port "$PORT_ATTEMPTS" start_listener "$dir" || {
        _fail "$(_port_attempts_msg)"
        return 1
    }
    port="$FREE_PORT"
    # golem-1 sends a hostile/buggy fractional-second ts fromdateiso8601 cannot
    # parse; golem-2 sends none (listener stamps a fresh valid one).
    post "$port" "/" '{"ts":"2026-07-21T10:00:00.123456Z","golem":"golem-1","event":"gate","message":"gate one"}' >/dev/null
    post "$port" "/" '{"golem":"golem-2","event":"gate","message":"gate two"}' >/dev/null
    # The malformed ts was re-stamped on ingress, so BOTH lines are parseable and
    # the jq pipeline never aborts.
    assert_file_not_contains "$dir/.worktrees/.status/feed.jsonl" '2026-07-21T10:00:00.123456Z' \
        "malformed ts is NOT written verbatim (re-stamped on ingress)"
    out="$(cd "$dir" && /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV HOME="$dir" \
        GOLEM_STATUS_DIR=.worktrees/.status "$REAL_BASH" "$GATE_WATCH" --once 2>/dev/null || true)"
    assert_contains "$out" "golem-1" "malformed-ts golem still surfaces"
    assert_contains "$out" "golem-2" "sibling well-formed golem NOT blanked by the bad ts"
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
    with_free_port "$PORT_ATTEMPTS" start_listener "$dir" || {
        _fail "$(_port_attempts_msg)"
        return 1
    }
    port="$FREE_PORT"
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
    command printf '{"issue":8,"golem":"golem-8"}\n' >"$dir/.worktrees/.status/golem-8.json"
    with_free_port "$PORT_ATTEMPTS" start_listener "$dir" || {
        _fail "$(_port_attempts_msg)"
        return 1
    }
    port="$FREE_PORT"
    assert_equals "400" "$(post "$port" "/" 'not json')" "invalid JSON → 400"
    assert_equals "400" "$(post "$port" "/" '[1,2,3]')" "non-object JSON → 400"
    # Oversized: exceed GOLEM_EVENT_MAX_BODY (default 65536) → 413.
    local big
    big="$(python3 -c 'print("{\"golem\":\"golem-8\",\"message\":\"" + "z"*70000 + "\"}")')"
    assert_equals "413" "$(post "$port" "/" "$big")" "oversized body → 413"
    # Wrong method on POST-only path.
    assert_equals "404" "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' \
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
    with_free_port "$PORT_ATTEMPTS" start_listener "$dir" || {
        _fail "$(_port_attempts_msg)"
        return 1
    }
    port="$FREE_PORT"
    out="$(curl -s --max-time 5 "http://127.0.0.1:$port/healthz" 2>/dev/null || true)"
    assert_contains "$out" "ok" "GET /healthz → ok"
    stop_listener
}

# The .sh shim FAILS LOUD (non-zero) when no python3>=3.11 is reachable — no
# silent no-op. Simulate "no python" with an empty PATH holding only bash/env.
test_shim_fails_loud_without_python() {
    local dir bindir rc out
    new_sandbox dir
    bindir="$dir/bin"
    command mkdir -p "$bindir"
    # Provide only the shell + a dirname/pwd the shim needs at startup, but NO
    # python3, so the version gate cannot be satisfied.
    for tool in bash env dirname pwd; do
        p="$(command -v "$tool" 2>/dev/null || true)"
        [ -n "$p" ] && command ln -sf "$p" "$bindir/$tool"
    done
    rc=0
    # Unset BASH_ENV: on a devcontainer it points at /etc/bash_env, which sources
    # /etc/bashrc.d/*.sh (one of which can block on an auth check) and would hang
    # the reduced-PATH child — the repo-standard PATH-stub-test precaution.
    out="$(/usr/bin/env --unset=BASH_ENV PATH="$bindir" "$REAL_BASH" "$LISTENER_SH" 2>&1)" || rc=$?
    assert_true "[ '$rc' -ne 0 ]" "shim exits non-zero when python3>=3.11 absent"
    assert_contains "$out" "python3>=3.11" "shim message names the Python floor"
}

# The retry path against the REAL listener (#780). Every case above exercises the
# happy path where the first port wins, so start_listener's failure branch — and
# _reap_failed_listener with it — is never reached by them.
#
# tests/validate-free-port.sh proves the with_free_port PRIMITIVE recovers, but
# only through a throwaway bind callback. That leaves the integration unproven:
# whether a lost race against the actual listener process reaps cleanly and the
# second attempt genuinely serves. Asserting the wiring with a source grep is not
# the same claim, and this is the one that matters at runtime.
#
# So: squat a real port, shadow the allocator to hand it out first, and drive the
# real start_listener through with_free_port. Attempt 1 must fail on the occupied
# port, be reaped, and attempt 2 must come up and answer a POST.
test_retry_recovers_against_the_real_listener() {
    if python_unavailable || curl_unavailable; then
        skip_test "python3>=3.11 / curl not available"
        return 0
    fi
    local dir squatted squat_pid code
    new_sandbox dir
    command printf '{"issue":5,"golem":"golem-5"}\n' >"$dir/.worktrees/.status/golem-5.json"

    # Hold a real port open for the duration.
    command cat >"$WORKDIR/squat.py" <<'PY'
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
with open(sys.argv[2], "w") as fh:
    fh.write(sys.argv[1])
time.sleep(120)
PY
    squatted="$(free_port)"
    command python3 "$WORKDIR/squat.py" "$squatted" "$WORKDIR/squatted" >/dev/null 2>&1 &
    squat_pid=$!
    local waited=0
    while [ ! -s "$WORKDIR/squatted" ]; do
        command kill -0 "$squat_pid" 2>/dev/null || break
        command sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -gt 50 ] && break
    done
    if [ ! -s "$WORKDIR/squatted" ]; then
        command kill "$squat_pid" 2>/dev/null || true
        skip_test "could not squat a port to simulate contention"
        return 0
    fi

    # Hand out the OCCUPIED port first, a real one after. The count lives in a
    # file because with_free_port calls the allocator in a command substitution
    # — a subshell, where a variable increment would be discarded.
    command printf '0\n' >"$WORKDIR/rl-calls"
    eval 'free_port() {
        local n
        n=$(( $(command cat "'"$WORKDIR"'/rl-calls") + 1 ))
        command printf "%s\n" "$n" >"'"$WORKDIR"'/rl-calls"
        if [ "$n" -eq 1 ]; then
            command printf "%s\n" "'"$squatted"'"
            return 0
        fi
        real_free_port
    }'

    if with_free_port "$PORT_ATTEMPTS" start_listener "$dir"; then
        assert_equals "2" "$(command cat "$WORKDIR/rl-calls")" \
            "The real listener lost the first port and retried exactly once"
        assert_true "[ \"$FREE_PORT\" != \"$squatted\" ]" \
            "It came up on a DIFFERENT port than the occupied one"
        code="$(post "$FREE_PORT" "/" '{"golem":"golem-5","event":"gate","message":"after retry"}')"
        assert_equals "204" "$code" "The retried listener actually serves"
        assert_file_contains "$dir/.worktrees/.status/feed.jsonl" '"message":"after retry"' \
            "and its POST reaches the feed"
        stop_listener
    else
        _fail "start_listener did not recover from an occupied port" \
            "log: $(command cat "$dir/listener.log" 2>/dev/null)"
    fi

    eval 'free_port() { real_free_port; }'
    command kill "$squat_pid" 2>/dev/null || true
    wait "$squat_pid" 2>/dev/null || true
}

# _reap_failed_listener must leave NOTHING for the retry to trip over. The stale
# pid is the sharp end: with LISTENER_PID uncleared, the EXIT trap and the next
# stop_listener would signal a number that, after enough pid churn, belongs to an
# unrelated process.
test_failed_start_is_reaped_and_pid_cleared() {
    if python_unavailable; then
        skip_test "python3>=3.11 not available"
        return 0
    fi
    local dir squatted squat_pid
    new_sandbox dir

    # FORCE the failure rather than skipping when it cannot be observed. The
    # obvious lever — bind privileged port 1 — is NOT usable: this suite runs as
    # root in the devcontainer, where port 1 binds fine and the case would skip
    # exactly where it needs to run (the self-skipping-test-hides-the-risky-branch
    # class). A squatted port fails for root and non-root alike.
    command cat >"$WORKDIR/squat2.py" <<'PY'
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
with open(sys.argv[2], "w") as fh:
    fh.write(sys.argv[1])
time.sleep(60)
PY
    squatted="$(free_port)"
    command rm -f "$WORKDIR/squatted2"
    command python3 "$WORKDIR/squat2.py" "$squatted" "$WORKDIR/squatted2" >/dev/null 2>&1 &
    squat_pid=$!
    local waited=0
    while [ ! -s "$WORKDIR/squatted2" ]; do
        command kill -0 "$squat_pid" 2>/dev/null || break
        command sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -gt 50 ] && break
    done
    if [ ! -s "$WORKDIR/squatted2" ]; then
        command kill "$squat_pid" 2>/dev/null || true
        _fail "could not squat a port to force a start failure"
        return 1
    fi

    if start_listener "$dir" "$squatted"; then
        stop_listener
        _fail "listener started on an OCCUPIED port" \
            "the fixture is not producing contention, so this case proves nothing"
    else
        assert_equals "" "$LISTENER_PID" \
            "A failed start clears LISTENER_PID, so no stale pid is ever signalled"
    fi

    command kill "$squat_pid" 2>/dev/null || true
    wait "$squat_pid" 2>/dev/null || true
}

# _reap_failed_listener's SIGKILL ESCALATION, driven for real (#825 item 3).
#
# test_failed_start_is_reaped_and_pid_cleared above forces its failure with a
# squatted port, so the listener fails to BIND and exits immediately: the poll
# loop breaks on its first iteration and the escalation branch is never reached.
# tests/validate-free-port.sh proves the bounded-reap SHAPE terminates against a
# SIGTERM-ignoring child, and that both sites use that shape — but neither claim
# drives THIS function down its own SIGKILL path. Between them a defect in the
# escalation (a missing `kill -KILL`, a diagnostic that never prints, a wait that
# blocks after it) would pass every test in the repo.
#
# So substitute a genuinely signal-immune child for the listener: set
# LISTENER_PID to a real process that ignores SIGTERM, call the production
# function, and require that it says so and terminates it anyway.
#
# It costs the production 5s bound (50 x 0.1s) on purpose. The alternative — a
# test-only knob shortening the poll — would mean the number under test is not
# the number that ships.
test_reap_escalates_to_sigkill() {
    if python_unavailable; then
        skip_test "python3>=3.11 not available"
        return 0
    fi
    command cat >"$WORKDIR/deaf.py" <<'PY'
import signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w") as fh:
    fh.write("up")
time.sleep(120)
PY
    command rm -f "$WORKDIR/deaf-up"
    command python3 "$WORKDIR/deaf.py" "$WORKDIR/deaf-up" >/dev/null 2>&1 &
    local deaf_pid=$! waited=0
    while [ ! -s "$WORKDIR/deaf-up" ]; do
        command kill -0 "$deaf_pid" 2>/dev/null || break
        command sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -gt 50 ] && break
    done
    if [ ! -s "$WORKDIR/deaf-up" ]; then
        command kill -9 "$deaf_pid" 2>/dev/null || true
        _fail "could not start a SIGTERM-ignoring child to stand in for the listener"
        return 1
    fi

    # The child really is immune, so this case cannot pass by the SIGTERM alone
    # working — without that arm, a reap that never escalated would still see a
    # dead process and look correct.
    command kill -TERM "$deaf_pid" 2>/dev/null || true
    command sleep 0.5
    assert_true "command kill -0 $deaf_pid 2>/dev/null" \
        "The stand-in ignores SIGTERM, so reaching SIGKILL is the only way it dies"

    LISTENER_PID="$deaf_pid"
    _reap_failed_listener 2>"$WORKDIR/reap.err"

    assert_file_contains "$WORKDIR/reap.err" "ignored SIGTERM" \
        "The escalation announces itself rather than killing silently"
    assert_contains "$(command cat "$WORKDIR/reap.err")" "$deaf_pid" \
        "and names the pid it had to SIGKILL"
    assert_true "! command kill -0 $deaf_pid 2>/dev/null" \
        "The wedged listener is dead — the reap escalated instead of blocking"
    assert_equals "" "$LISTENER_PID" \
        "and LISTENER_PID is cleared, so no stale pid is ever signalled"
}

# --- Runner -----------------------------------------------------------------

run_test test_prereqs "prerequisites: python3>=3.11 + curl + files present"
run_test test_post_gate_surfaces_via_gatewatch "gate POST → feed → gate-watch --once surfaces it (AC1/AC3)"
run_test test_post_escalation_preserves_kind "escalation POST keeps its kind in the feed"
run_test test_normalization_defaults "normalization: absent ts re-stamped, absent event → gate, null message → default"
run_test test_malformed_ts_does_not_blank_floor "malformed client ts re-stamped — does not blank the BLOCKED floor (correctness#2)"
run_test test_orphan_sentinel_not_appended "orphan golem-? ACKed but not appended"
run_test test_bad_requests_rejected_without_crash "bad/oversized/wrong-method rejected without crash"
run_test test_healthz "GET /healthz liveness probe"
run_test test_shim_fails_loud_without_python "shim fails loud when python3>=3.11 absent (no bash fallback)"
run_test test_retry_recovers_against_the_real_listener "retry recovers against the REAL listener (#780)"
run_test test_failed_start_is_reaped_and_pid_cleared "a failed start is reaped and clears LISTENER_PID (#780)"
run_test test_reap_escalates_to_sigkill "the reap escalates to SIGKILL on a SIGTERM-immune listener (#825)"

generate_report
