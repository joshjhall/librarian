#!/usr/bin/env bash
# Ephemeral-port allocation + retry helper — tests/lib/free-port.sh (issue #780).
#
# WHAT THIS GATE EXISTS TO PROVE. Two suites allocate a port by binding
# `127.0.0.1:0`, reading it back, and closing, then start a server on the NUMBER.
# The window between close and real bind is a TOCTOU another process can win.
# #780's fix is a shared allocate-and-retry helper — and its AC4 says to exercise
# the recovery DELIBERATELY, "rather than trusting a race that does not
# reproduce". The race has been observed zero times in CI, so a test that merely
# calls the helper and watches it succeed would prove nothing: it would pass
# identically against a one-shot allocator.
#
# So the fixture manufactures the lost race instead of waiting for one. A real
# socket SQUATS a real port and holds it for the duration; the allocator is
# shadowed to hand that squatted port out FIRST; and the callback performs a
# GENUINE bind of whatever port it is handed. Attempt 1 therefore fails the way a
# lost race fails — on an occupied port, at bind time, not at allocation time.
#
# THE TEETH ARE THE DIVERGENCE ARM. `attempts=2` recovering is only evidence when
# `attempts=1` against the IDENTICAL fixture fails. Without that arm the recovery
# case is a tautology that passes with and without the retry — the failure mode
# this repo has hit repeatedly (fixture-must-express-the-divergent-case). The two
# arms differ in exactly one input: the attempt count.
#
# Runtime: python3 (any version — only `socket` is used, so the 3.11 floor the
# shipped tools carry does not apply). Skips cleanly when it is absent.
# bash-3.2 + BSD grep/sed clean; `command`-prefixed coreutils per convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
# shellcheck source=tests/lib/free-port.sh
source "$SCRIPT_DIR/lib/free-port.sh"

test_suite "free-port allocation + retry (#780)"

python_missing() { ! command -v python3 >/dev/null 2>&1; }

# Keep the REAL allocator under a second name so a shadowed free_port can still
# delegate to it — and so restoring after a fixture needs no second copy of the
# allocation idiom (which test_no_third_copy_of_the_idiom below would flag, in
# this very file). `declare -f` prints the definition; dropping its first line
# leaves the body to re-attach under the new name. bash-3.2 supports both.
eval "real_free_port() $(declare -f free_port | command sed '1d')"

# restore_alloc — put the plain delegating allocator back after a fixture.
restore_alloc() { eval 'free_port() { real_free_port; }'; }
restore_alloc

SQUATTED=""

WORKDIR="$(command mktemp -d)"
SQUAT_PID=""
cleanup() {
    [ -n "$SQUAT_PID" ] && command kill "$SQUAT_PID" 2>/dev/null || true
    command rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- Fixture: a genuinely occupied port -------------------------------------

# squat_one <port> — ONE squat attempt: bind <port> and HOLD it in a live
# process. Returns 0 once the port is confirmed held.
#
# It must keep the socket OPEN (that is the whole point — an allocate-and-close
# would leave the port free and the fixture would prove nothing), and it must
# listen(), so a competing bind fails rather than being absorbed by SO_REUSEADDR
# on some platforms.
#
# The port is passed IN rather than read back from a bind-0 — deliberately, so
# this file never contains the allocation idiom that
# test_no_third_copy_of_the_idiom greps for. A fixture carrying the very pattern
# the gate bans would make that gate unable to tell a real copy from itself.
squat_one() {
    command python3 "$WORKDIR/squat.py" "$1" "$WORKDIR/squatted" >/dev/null 2>&1 &
    SQUAT_PID=$!

    local waited=0
    while [ ! -s "$WORKDIR/squatted" ]; do
        # The squatter died — that port was taken from under us. Fail this
        # attempt so with_free_port hands us a fresh one.
        command kill -0 "$SQUAT_PID" 2>/dev/null || {
            wait "$SQUAT_PID" 2>/dev/null || true
            SQUAT_PID=""
            return 1
        }
        command sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -gt 50 ]; then
            command kill "$SQUAT_PID" 2>/dev/null || true
            SQUAT_PID=""
            return 1
        fi
    done
    return 0
}

# squat_port — hold a real port for the duration of a test, setting SQUATTED.
#
# It squats THROUGH with_free_port, which is a nice property rather than a
# circularity: the helper is already proven to hand out a bindable port by
# test_free_port_allocates_a_bindable_port, and letting it retry here means the
# fixture itself cannot flake on the very race it exists to simulate.
squat_port() {
    command rm -f "$WORKDIR/squatted"
    command cat >"$WORKDIR/squat.py" <<'PY'
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
with open(sys.argv[2], "w") as fh:
    fh.write(sys.argv[1])
time.sleep(300)
PY
    with_free_port 3 squat_one || return 1
    SQUATTED="$FREE_PORT"
}

# try_bind <port> — the callback under test. A GENUINE bind: succeeds on a free
# port, fails on the squatted one. This is what makes the fixture a real
# contention test rather than a mocked return code.
try_bind() {
    command python3 - "$1" >/dev/null 2>&1 <<'PY'
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.close()
PY
}

# try_bind_logged <logfile> <port> — same, recording each port it was handed so a
# test can assert the SECOND attempt used a DIFFERENT port (a retry that re-tried
# the same number would recover from nothing).
try_bind_logged() {
    command printf '%s\n' "$2" >>"$1"
    try_bind "$2"
}

# shadow_alloc_squatted_then_real — replace free_port so its FIRST call returns
# the squatted port and every later call delegates to the real allocator.
#
# This is the seam with_free_port was written for: it calls `free_port` by NAME
# rather than inlining the python, precisely so a fixture can inject contention
# without a test-only branch inside the code under test.
#
# THE CALL COUNT IS KEPT IN A FILE, not a variable. with_free_port invokes the
# allocator as `port="$(free_port)"` — a command substitution, i.e. a SUBSHELL —
# so a shell-variable increment is discarded when it exits and the shadow would
# hand out the squatted port on every attempt, never advancing. Observed exactly
# that: the counter read 0 after two real calls, and the retry "failed to
# recover" from a fixture that was in fact re-serving the occupied port forever.
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

# alloc_calls — how many times the shadowed allocator was invoked.
alloc_calls() { command cat "$WORKDIR/alloc-calls" 2>/dev/null || command printf '0\n'; }

# --- Tests ------------------------------------------------------------------

# The helper alone: a port it hands out is real and bindable.
test_free_port_allocates_a_bindable_port() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    local p
    p="$(real_free_port)" || {
        _fail "real_free_port returned non-zero"
        return 1
    }
    assert_not_empty "$p" "free_port emits a port"
    assert_true "[ \"$p\" -gt 0 ] && [ \"$p\" -lt 65536 ]" \
        "free_port emits a plausible TCP port"
    assert_true "try_bind $p" "The emitted port is actually bindable"
}

# The fail-loud branch, driven by FORCING the runtime absent rather than by
# skipping when it happens to be (the self-skipping-test-hides-the-risky-branch
# class: a skip-if-absent guard only ever covers the present arm, and this repo's
# CI always has python3, so that branch would never run anywhere).
#
# An empty PATH is what makes `command python3` unresolvable. The assertion that
# matters is the RETURN CODE: a silent empty echo here is the failure mode the
# fail-loud posture exists to prevent — a caller would start a server on "" and
# report a confusing downstream error instead of the real cause.
test_missing_runtime_fails_loud() {
    local out rc
    out="$(PATH="$WORKDIR/empty-path" free_port 2>"$WORKDIR/noruntime.err")"
    rc=$?
    assert_true "[ $rc -ne 0 ]" "free_port returns NON-ZERO when no python3 resolves"
    assert_equals "" "$out" "It emits no port on stdout"
    assert_file_contains "$WORKDIR/noruntime.err" "could not allocate" \
        "It says why on stderr rather than failing mutely"
}

# AC4 — the recovery. Attempt 1 hits a genuinely occupied port and fails at BIND
# time; the retry re-allocates and succeeds.
test_retry_recovers_from_an_occupied_port() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    squat_port || {
        _fail "could not squat a port"
        return 1
    }
    shadow_alloc_squatted_then_real

    local log="$WORKDIR/attempts-2.log"
    : >"$log"
    if with_free_port 2 try_bind_logged "$log"; then
        assert_equals "2" "$(alloc_calls)" \
            "A lost race costs exactly one extra allocation"
        assert_true "[ -n \"$FREE_PORT\" ]" "FREE_PORT is set to the winning port"
        assert_true "[ \"$FREE_PORT\" != \"$SQUATTED\" ]" \
            "The winning port is NOT the squatted one"
        assert_equals "2" "$(command wc -l <"$log" | command tr -d ' ')" \
            "The callback ran twice — the retry re-attempts the START, not just the allocation"
        assert_equals "$SQUATTED" "$(command sed -n '1p' "$log")" \
            "Attempt 1 was handed the occupied port"
    else
        _fail "with_free_port 2 did not recover from an occupied port"
    fi
    restore_alloc
}

# THE TEETH. Same fixture, same squatted port, attempts=1 — must FAIL. Without
# this arm the case above passes whether or not the retry exists.
test_single_attempt_fails_on_the_same_fixture() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    squat_port || {
        _fail "could not squat a port"
        return 1
    }
    shadow_alloc_squatted_then_real

    if with_free_port 1 try_bind; then
        _fail "with_free_port 1 SUCCEEDED against an occupied port" \
            "the fixture is not producing real contention — the recovery test above proves nothing"
    else
        assert_equals "1" "$(alloc_calls)" "attempts=1 allocates exactly once"
        assert_equals "" "$FREE_PORT" \
            "An exhausted retry leaves FREE_PORT EMPTY — a caller cannot mistake it for a usable port"
    fi
    restore_alloc
}

# The port is appended LAST, after the caller's leading args. That contract is
# what lets both real call sites pass their existing `<sandbox> <port>` starter
# with no wrapper closure.
test_port_is_appended_after_leading_args() {
    if python_missing; then
        skip_test "python3 not available"
        return 0
    fi
    local out="$WORKDIR/args.txt"
    record_args() {
        command printf '%s\n' "$*" >"$out"
        return 0
    }
    with_free_port 2 record_args alpha beta || {
        _fail "with_free_port failed on a trivially-succeeding callback"
        return 1
    }
    assert_equals "alpha beta $FREE_PORT" "$(command cat "$out")" \
        "Callback receives its leading args first and the port LAST"
    unset -f record_args
}

# A bad attempt count is a caller bug, not a lost race — it must not silently
# behave like attempts=1.
test_zero_attempts_is_rejected() {
    # FREE_PORT is seeded with a sentinel and with_free_port is called IN THIS
    # SHELL, redirecting stderr to a file rather than into a `$(...)`. A command
    # substitution would run it in a SUBSHELL, so its `FREE_PORT=""` would never
    # reach the assertion below — which would then be reading a value this test
    # set itself and passing no matter what the helper did. (Caught by the
    # mutation round: the substitution form went on passing until an unrelated
    # mutation left a stale port in the parent.)
    FREE_PORT="sentinel-not-cleared"
    if with_free_port 0 true 2>"$WORKDIR/zero.err"; then
        _fail "with_free_port 0 succeeded" "an attempts<1 caller bug must fail loud"
        return 1
    fi
    assert_equals "" "$FREE_PORT" "A rejected attempt count leaves FREE_PORT empty"
    assert_file_contains "$WORKDIR/zero.err" "attempts must be >= 1" \
        "The rejection says what was wrong, not just that something was"
}

# AC2 — the retry logic is SHARED, not a third copy. #780 exists because the
# second call site copied the first rather than inventing it; the third copy is
# the thing to prevent structurally instead of by review.
#
# The socket call that reads a bound address back is the discriminating token
# (assembled from halves in the test body below, never written whole here — see
# the self-match note). It is what the
# allocate-read-back-close idiom needs and what a bind-and-KEEP server (e.g. the
# stub gateway in validate-token-report.sh, which binds `("127.0.0.1", 0)` and
# then serves on it) does NOT use. That distinction is why the grep keys off it
# rather than off the bind line, which would flag the race-free shape too.
#
# This file never contains the token itself — it is assembled below — so the
# checker cannot self-match (the escaped-fixture-cannot-self-match class).
test_no_third_copy_of_the_idiom() {
    local token hits
    token="get""sockname"
    hits="$(cd "$REPO_ROOT" && command grep -rl "$token" tests/ 2>/dev/null | command sort || true)"
    assert_equals "tests/lib/free-port.sh" "$hits" \
        "The bind-0 allocation idiom lives in exactly ONE file under tests/"
    if [ "$hits" != "tests/lib/free-port.sh" ]; then
        command printf '    files carrying the allocation idiom:\n' >&2
        command printf '      %s\n' $hits >&2
    fi
}

# The two real call sites route through the helper. Asserted statically so it
# holds on a host that skips the behavioral suites for want of a runtime.
test_both_call_sites_use_the_helper() {
    assert_file_contains "$REPO_ROOT/tests/validate-golem-event-listener.sh" \
        "with_free_port 2 start_listener" \
        "The behavioral gate starts its listener through the retry helper"
    assert_file_contains "$REPO_ROOT/tests/coverage-python.sh" \
        "lib/free-port.sh" \
        "The coverage entry point sources the helper (not the sourced fragment)"
    assert_file_contains "$REPO_ROOT/tests/python-corpus/90-workflow-tool-drivers.sh" \
        "with_free_port 2 _cov_start_listener" \
        "The coverage driver starts its listener through the retry helper"
    # AC3: the degraded path stays non-fatal AND visible. A `[FAIL]`/`exit 1`
    # here would fail a run over an optional component.
    assert_file_contains "$REPO_ROOT/tests/python-corpus/90-workflow-tool-drivers.sh" \
        "did not start after 2 port attempts" \
        "The coverage driver's degraded note names the retry"
    assert_file_not_contains "$REPO_ROOT/tests/python-corpus/90-workflow-tool-drivers.sh" \
        "no free port; skipping" \
        "The old un-retried allocation-failure note is gone"
}

run_test test_free_port_allocates_a_bindable_port "free_port yields a bindable port"
run_test test_missing_runtime_fails_loud "Absent python3 fails loud, never an empty port"
run_test test_retry_recovers_from_an_occupied_port "Retry recovers from a genuinely occupied port"
run_test test_single_attempt_fails_on_the_same_fixture "attempts=1 fails on the same fixture (teeth)"
run_test test_port_is_appended_after_leading_args "Port is appended after the caller's args"
run_test test_zero_attempts_is_rejected "attempts<1 is rejected"
run_test test_no_third_copy_of_the_idiom "No third copy of the allocation idiom"
run_test test_both_call_sites_use_the_helper "Both call sites route through the helper"

generate_report
