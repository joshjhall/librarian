#!/usr/bin/env bash
# Coverage-driver listener start attempt — tests/lib/cov-listener.sh (issue #825).
#
# WHAT THIS GATE EXISTS TO PROVE. #780 routed BOTH listener start sites through
# the shared allocate-and-retry helper, but gave them asymmetric test treatment.
# `start_listener` (tests/validate-golem-event-listener.sh) got a real end-to-end
# retry test against a squatted port. `_cov_start_listener` got nothing that
# EXECUTES it: two static assert_file_contains checks on its source text, plus
# the generic with_free_port tests — which drive a throwaway `try_bind` callback
# and never reach this function at all. Its failed-attempt reap (kill, bounded
# poll, SIGKILL, wait, clear LISTENER_PID) had therefore never once run under a
# genuinely lost race, and a defect anywhere in it would have passed the entire
# suite. This file closes that asymmetry.
#
# The obstacle was structural, not effort: the function was defined INSIDE a
# sourced coverage fragment that presupposes run_coverage/exec_coverage/WORKDIR,
# so no test could source and call it. #825 resolved that by extracting it to
# tests/lib/cov-listener.sh — the same remedy #780 applied to the allocator — and
# this suite is what that extraction was FOR.
#
# THE SEAMS THIS SUITE USES, both pre-existing and neither a test-only hook:
#
#   * `free_port` is called BY NAME by with_free_port, so shadowing the allocator
#     hands out a port a real socket has already squatted. Attempt 1 then fails
#     the way a lost race fails — on an occupied port, at BIND time, not at
#     allocation time.
#   * `LISTENER_PY` is read as a global (see that lib's header for why it must
#     stay one), so pointing it at a fixture substitutes the process under
#     supervision without touching the function.
#
# WHY exec_coverage IS STUBBED AS A PLAIN `exec python3`. What is under test is
# start / readiness / reap; coverage.py's presence changes none of it, and
# requiring it would make this gate skip on hosts where the behaviour it covers
# still runs. The stub still EXECs, which is the load-bearing half: `exec`
# replaces the backgrounded subshell so $! addresses the real child, and a
# regression that dropped it would orphan the process and surface here as a
# still-alive pid rather than passing quietly.
#
# THE TEETH ARE THE DIVERGENCE ARM, as in the sibling suite: `PORT_ATTEMPTS`
# recovering is evidence only because attempts=1 against the IDENTICAL fixture
# fails. Without it the recovery case is a tautology that passes with and without
# the retry.
#
# Runtime: python3 (any version — the fixtures use only socket/signal/http, so
# the 3.11 floor the shipped listener carries does not apply, and this suite
# never runs the shipped listener). Skips cleanly when it is absent.
# bash-3.2 + BSD grep/sed clean; `command`-prefixed coreutils per convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=tests/lib/free-port.sh
source "$SCRIPT_DIR/lib/free-port.sh"
# shellcheck source=tests/lib/cov-listener.sh
source "$SCRIPT_DIR/lib/cov-listener.sh"

test_suite "coverage-driver listener start attempt (#825)"

python_missing() { ! command -v python3 >/dev/null 2>&1; }

# Keep the REAL allocator under a second name so a shadowed free_port can still
# delegate to it. `declare -f` prints the definition; dropping its first line
# leaves the body to re-attach under the new name. bash-3.2 supports both. Same
# idiom, and same reason, as tests/validate-free-port.sh.
eval "real_free_port() $(declare -f free_port | command sed '1d')"
restore_alloc() { eval 'free_port() { real_free_port; }'; }
restore_alloc

WORKDIR="$(command mktemp -d)"
SQUAT_PID=""

# The globals tests/lib/cov-listener.sh reads from its caller. PLUGINS_DIR is
# only interpolated into the coverage `--source=` flag, which the stub ignores;
# LISTENER_PY and LISTENER_PID are the ones that matter. Each case re-points
# LISTENER_PY at the fixture it needs — that global IS the injection seam (see
# that lib's header for why it must stay a global).
#
# Read by the SOURCED lib, across a boundary shellcheck cannot follow — the same
# situation tests/lib/free-port.sh documents for FREE_PORT, in the other
# direction.
# shellcheck disable=SC2034
{
    PLUGINS_DIR="$WORKDIR/plugins"
    LISTENER_PY=""
    LISTENER_PID=""
}

cleanup() {
    [ -n "$LISTENER_PID" ] && command kill -9 "$LISTENER_PID" 2>/dev/null || true
    [ -n "$SQUAT_PID" ] && command kill "$SQUAT_PID" 2>/dev/null || true
    command rm -rf "$WORKDIR"
}
trap cleanup EXIT

# exec_coverage — the stub the lib invokes. `exec` is preserved deliberately (see
# the header): it is the difference between $! addressing the real child and
# addressing a subshell wrapper that leaves the child orphaned.
exec_coverage() {
    # Drop coverage.py's own arguments (`run --parallel-mode --source=...`) and
    # exec the script they wrap. Everything from the first non-flag onward is the
    # command line the real runner would have measured.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            run | --parallel-mode | --source=*) shift ;;
            *) break ;;
        esac
    done
    exec python3 "$@"
}

# --- Fixtures ---------------------------------------------------------------

# write_fixtures — the three stand-in "listeners", each a real process.
#
#   serving.py  binds the port and answers /healthz "ok" — the success path.
#   deaf.py     ignores SIGTERM and NEVER binds — so the readiness poll genuinely
#               exhausts and the reap's SIGKILL escalation is reached. Both
#               halves are needed: a binding deaf process would be reachable and
#               never enter the reap; a non-binding responsive one would die on
#               the first SIGTERM and never escalate. It records its OWN pid to
#               $WEDGED_PID_FILE, which is the only handle a test has on the
#               process the reap must kill: the diagnostic names no pid, and
#               LISTENER_PID is set inside the function and cleared before it
#               returns. The path arrives by ENVIRONMENT because the lib invokes
#               the script with no arguments of its own.
write_fixtures() {
    command mkdir -p "$WORKDIR/fx"
    command cat >"$WORKDIR/fx/serving.py" <<'PY'
import http.server, os, socketserver


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok\n")

    def log_message(self, *a):
        pass


port = int(os.environ["GOLEM_EVENT_LISTEN_PORT"])
socketserver.TCPServer(("127.0.0.1", port), H).serve_forever()
PY
    command rm -f "$WORKDIR/wedged.pid"
    command cat >"$WORKDIR/fx/deaf.py" <<'PY'
import os, signal, time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["WEDGED_PID_FILE"], "w") as fh:
    fh.write(str(os.getpid()))
time.sleep(300)
PY
    command cat >"$WORKDIR/fx/squat.py" <<'PY'
import socket, sys, time

s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
with open(sys.argv[2], "w") as fh:
    fh.write(sys.argv[1])
time.sleep(300)
PY
}

# squat_one <port> — ONE squat attempt: bind <port> and HOLD it in a live
# process that listen()s, so a competing bind fails rather than being absorbed by
# SO_REUSEADDR. Returns 0 once the port is confirmed held.
squat_one() {
    command python3 "$WORKDIR/fx/squat.py" "$1" "$WORKDIR/squatted" >/dev/null 2>&1 &
    SQUAT_PID=$!
    local waited=0
    while [ ! -s "$WORKDIR/squatted" ]; do
        command kill -0 "$SQUAT_PID" 2>/dev/null || {
            wait "$SQUAT_PID" 2>/dev/null || true
            SQUAT_PID=""
            return 1
        }
        command sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -gt 50 ] && {
            command kill "$SQUAT_PID" 2>/dev/null || true
            SQUAT_PID=""
            return 1
        }
    done
    return 0
}

# squat_port — hold a real port for the duration of a case, setting SQUATTED. It
# squats THROUGH with_free_port so the fixture itself cannot flake on the very
# race it exists to simulate.
SQUATTED=""
squat_port() {
    command rm -f "$WORKDIR/squatted"
    with_free_port 3 squat_one || return 1
    SQUATTED="$FREE_PORT"
}

release_squat() {
    [ -n "$SQUAT_PID" ] && command kill "$SQUAT_PID" 2>/dev/null || true
    [ -n "$SQUAT_PID" ] && wait "$SQUAT_PID" 2>/dev/null || true
    SQUAT_PID=""
}

# shadow_alloc_squatted_then_real — free_port's FIRST call returns the squatted
# port, every later call delegates to the real allocator.
#
# THE CALL COUNT IS KEPT IN A FILE, not a variable. with_free_port invokes the
# allocator as `port="$(free_port)"` — a command substitution, i.e. a SUBSHELL —
# so a shell-variable increment is discarded on exit and the shadow would hand
# out the squatted port on EVERY attempt, never advancing. The retry would then
# appear to "fail to recover" from a fixture that was in fact re-serving the
# occupied port forever.
shadow_alloc_squatted_then_real() {
    command printf '0\n' >"$WORKDIR/alloc-calls"
    eval 'free_port() {
        local n
        n=$(( $(command cat "$WORKDIR/alloc-calls") + 1 ))
        command printf "%s\n" "$n" >"$WORKDIR/alloc-calls"
        if [ "$n" -eq 1 ]; then
            command printf "%s\n" "$SQUATTED"
            return 0
        fi
        real_free_port
    }'
}

alloc_calls() { command cat "$WORKDIR/alloc-calls" 2>/dev/null || command printf '0\n'; }

# stop_served — shut down a listener this suite successfully started.
stop_served() {
    [ -n "$LISTENER_PID" ] && command kill -9 "$LISTENER_PID" 2>/dev/null || true
    [ -n "$LISTENER_PID" ] && wait "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""
}

# --- Tests ------------------------------------------------------------------

# The happy path, so the fixture is known to be capable of succeeding before any
# case reads a failure as meaningful. Without this, a broken stub would make
# every failure-arm below pass for the wrong reason.
test_a_free_port_starts_and_serves() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    write_fixtures
    LISTENER_PY="$WORKDIR/fx/serving.py"
    LISTENER_PID=""

    assert_true "with_free_port \"\$PORT_ATTEMPTS\" _cov_start_listener \"$WORKDIR\"" \
        "_cov_start_listener starts and answers /healthz on a free port"
    assert_not_empty "$LISTENER_PID" \
        "and leaves LISTENER_PID set for the caller's shutdown"
    stop_served
}

# ITEM 1, the case this suite was filed for: drive the REAL _cov_start_listener
# through with_free_port against a genuinely squatted port. Attempt 1 must fail
# and be REAPED — the process actually dead and LISTENER_PID cleared — and
# attempt 2 must serve. This mirrors the behavioral gate's
# test_retry_recovers_against_the_real_listener, which is what #825 asked for.
test_retry_recovers_against_the_real_starter() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    write_fixtures
    LISTENER_PY="$WORKDIR/fx/serving.py"
    LISTENER_PID=""

    if ! squat_port; then
        skip_test "could not squat a port to simulate contention"
        return 0
    fi
    shadow_alloc_squatted_then_real

    if with_free_port "$PORT_ATTEMPTS" _cov_start_listener "$WORKDIR"; then
        assert_equals "2" "$(alloc_calls)" \
            "It lost the first port and retried exactly once"
        assert_true "[ \"\$FREE_PORT\" != \"$SQUATTED\" ]" \
            "It came up on a DIFFERENT port than the occupied one"
        assert_true "command kill -0 $LISTENER_PID 2>/dev/null" \
            "and the surviving pid is the LIVE second attempt, not a reaped corpse"
        stop_served
    else
        _fail "_cov_start_listener did not recover from an occupied port"
    fi

    restore_alloc
    release_squat
}

# THE TEETH. attempts=1 against the IDENTICAL fixture must fail — otherwise the
# recovery above proves nothing, since it would pass against a one-shot
# allocator too.
test_single_attempt_fails_on_the_same_fixture() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    write_fixtures
    LISTENER_PY="$WORKDIR/fx/serving.py"
    LISTENER_PID=""

    if ! squat_port; then
        skip_test "could not squat a port to simulate contention"
        return 0
    fi
    shadow_alloc_squatted_then_real

    if with_free_port 1 _cov_start_listener "$WORKDIR"; then
        stop_served
        _fail "with_free_port 1 SUCCEEDED against an occupied port" \
            "the fixture is not producing contention, so the recovery case has no teeth"
    else
        assert_equals "" "$FREE_PORT" \
            "An exhausted retry leaves FREE_PORT empty, never a port nobody won"
    fi

    restore_alloc
    release_squat
}

# A FAILED attempt must leave nothing for the retry to trip over. The stale pid
# is the sharp end: with LISTENER_PID uncleared, the driver's SIGTERM shutdown
# would signal a number that, after enough pid churn, belongs to an unrelated
# process.
test_failed_attempt_is_reaped_and_pid_cleared() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    write_fixtures
    LISTENER_PY="$WORKDIR/fx/serving.py"
    LISTENER_PID=""

    if ! squat_port; then
        skip_test "could not squat a port to simulate contention"
        return 0
    fi

    # Call the function DIRECTLY on the occupied port — no retry — so the failure
    # branch is the only thing under observation.
    local doomed=""
    if _cov_start_listener "$WORKDIR" "$SQUATTED"; then
        doomed="$LISTENER_PID"
        stop_served
        _fail "_cov_start_listener started on an OCCUPIED port" \
            "the fixture is not producing contention, so this case proves nothing" \
            "pid: $doomed"
    else
        assert_equals "" "$LISTENER_PID" \
            "A failed attempt clears LISTENER_PID, so no stale pid is ever signalled"
    fi

    release_squat
}

# ITEM 3: the reap's SIGKILL ESCALATION, driven down the PRODUCTION path.
#
# The case above cannot reach it: a squatted port makes the child fail to bind
# and exit at once, so the poll loop breaks on its first iteration. Reaching the
# escalation needs a child that is ALIVE and never becomes ready AND ignores
# SIGTERM — which is what fx/deaf.py is. tests/validate-free-port.sh proves the
# reap SHAPE terminates against such a child and that both sites use that shape;
# neither claim drives THIS function down its own escalation branch.
#
# It costs the production bound (50 x 0.1s readiness + 50 x 0.1s reap, ~10s) on
# purpose: a test-only knob shortening either loop would mean the numbers under
# test are not the numbers that ship.
test_wedged_attempt_escalates_to_sigkill() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    write_fixtures
    # shellcheck disable=SC2034  # read by the sourced lib
    LISTENER_PY="$WORKDIR/fx/deaf.py"
    LISTENER_PID=""

    local port
    port="$(free_port)" || {
        skip_test "could not allocate a port"
        return 0
    }

    # `|| rc=$?` rather than a bare call: this attempt is EXPECTED to fail, and
    # under `set -e` a bare non-zero statement would abort the body before a
    # single assertion ran. `rc` is declared on its own line first, because
    # `local rc=$?` captures declare's status rather than the call's.
    local rc=0 wedged_pid
    WEDGED_PID_FILE="$WORKDIR/wedged.pid" \
        _cov_start_listener "$WORKDIR" "$port" >"$WORKDIR/wedged.out" 2>&1 || rc=$?
    wedged_pid="$(command cat "$WORKDIR/wedged.pid" 2>/dev/null || true)"

    assert_true "[ $rc -ne 0 ]" \
        "A listener that never answers /healthz is a FAILED attempt, not a silent success"
    assert_file_contains "$WORKDIR/wedged.out" "ignored SIGTERM" \
        "The escalation announces itself rather than killing silently"
    assert_equals "" "$LISTENER_PID" \
        "and LISTENER_PID is cleared even on the escalated path"
    # Not silently conditional: an empty wedged.pid means the deaf child never
    # ran, so whatever produced the escalation above was something else and this
    # case's evidence is worthless. Assert it rather than skipping the check.
    assert_not_empty "$wedged_pid" \
        "The deaf child really started (else nothing here is evidence about the reap)"
    if [ -n "$wedged_pid" ]; then
        assert_true "! command kill -0 $wedged_pid 2>/dev/null" \
            "The wedged child is dead — the reap escalated instead of blocking forever"
    fi
}

run_test test_a_free_port_starts_and_serves "A free port starts and serves (the fixture can succeed)"
run_test test_retry_recovers_against_the_real_starter "Retry recovers against the REAL _cov_start_listener"
run_test test_single_attempt_fails_on_the_same_fixture "attempts=1 fails on the same fixture (teeth)"
run_test test_failed_attempt_is_reaped_and_pid_cleared "A failed attempt is reaped and clears LISTENER_PID"
run_test test_wedged_attempt_escalates_to_sigkill "A wedged attempt escalates to SIGKILL"

generate_report
