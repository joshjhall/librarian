# shellcheck shell=bash
# Coverage-driver listener start attempt — one START ATTEMPT for
# scripts/golem-event-listener.py under `coverage run` (issues #780, #825).
#
# WHY THIS IS A SHARED LIB RATHER THAN A FUNCTION IN THE FRAGMENT. It was defined
# inside tests/python-corpus/90-workflow-tool-drivers.sh, a fragment SOURCED by
# tests/coverage-python.sh mid-run, which presupposes run_coverage/exec_coverage/
# WORKDIR/run_count already exist. A test could therefore not source and call it,
# and #780 shipped it with only STATIC assert_file_contains coverage while its
# sibling start site (start_listener, tests/validate-golem-event-listener.sh) got
# a real end-to-end retry test. Its failed-attempt reap — kill, bounded poll,
# SIGKILL, wait, clear LISTENER_PID — was never once executed, so a defect in it
# would have passed every test in the repo. That asymmetry IS #825 item 1.
#
# Extraction is the same remedy tests/lib/free-port.sh already applied to the
# allocator in #780, and it obeys the #564 split-suite contract: shared plumbing
# is sourced by ENTRY POINTS (tests/coverage-python.sh,
# tests/validate-cov-listener.sh), never by a sourced fragment.
#
# WHAT DELIBERATELY STAYED GLOBAL. The function reads LISTENER_PY, PLUGINS_DIR
# and exec_coverage from its caller instead of taking them as arguments. That is
# not laziness: tests/validate-coverage-corpus.sh proves every declared tool
# reaches a genuine `(run_coverage|exec_coverage).*"$VAR"` invocation, keyed off
# the variable whose assignment ends in the tool's basename. Renaming
# LISTENER_PY to a positional here would make golem-event-listener.py read as
# `declared-but-never-invoked` and gut that gate. Keeping the global preserves
# its teeth AND gives tests/validate-cov-listener.sh its injection seam — the
# same role `free_port` plays for the allocator, for the same reason.
#
# Sourced by ENTRY POINTS only. Pure bash-3.2 + python3.

# _cov_start_listener <sandbox> <port> — one START ATTEMPT: background the
# listener under coverage on <port> and poll /healthz until it answers.
# Returns 0 when it served, non-zero otherwise (setting LISTENER_PID for the
# caller to signal on success).
#
# Extracted into a function so with_free_port can RE-RUN it (#780). The retry
# has to wrap the start, not the allocation: `free_port` succeeds whether or
# not the race was lost — it is this bind that fails.
#
# Port LAST in the signature, per the with_free_port contract, so
# `with_free_port "$PORT_ATTEMPTS" _cov_start_listener "$LISTENER_SB"` composes
# directly.
_cov_start_listener() {
    # `local`, so the scope is enforced structurally rather than by every
    # call site remembering to `unset`. LISTENER_PID stays global on purpose
    # — the caller's success-path shutdown (in the 90- driver fragment) and the
    # caller itself both need it.
    local _csl_sb="$1" _csl_port="$2" _csl_tries=0 _csl_waited=0

    # `exec` inside the backgrounded subshell is load-bearing: without it,
    # $! is the SUBSHELL's pid, the reap's SIGTERM hits only that wrapper,
    # and the real coverage process is ORPHANED — it survives the script and,
    # never having exited cleanly, never flushes its data file. Measured:
    # the handler and serve_forever lines came back UNMEASURED while the
    # driver still reported success, and a stray listener was left running.
    # exec replaces the subshell, so $! addresses the process that must
    # receive the signal.
    (cd "$_csl_sb" && export GOLEM_EVENT_LISTEN_ADDR=127.0.0.1 \
        GOLEM_EVENT_LISTEN_PORT="$_csl_port" GOLEM_EVENT_MAX_BODY=512 &&
        exec_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$LISTENER_PY" >/dev/null 2>&1) &
    LISTENER_PID=$!

    # Bounded readiness poll, bailing out early if the process already died.
    while [ "$_csl_tries" -lt 50 ]; do
        if python3 - "$_csl_port" <<'PY' >/dev/null 2>&1; then
import sys, urllib.request
urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/healthz", timeout=1).read()
PY
            return 0
        fi
        kill -0 "$LISTENER_PID" 2>/dev/null || break
        sleep 0.1
        _csl_tries=$((_csl_tries + 1))
    done

    # A FAILED attempt must leave nothing behind for the retry to trip over:
    # reap the child (it may be a bind-collision corpse, or alive but wedged
    # past the readiness poll) and clear LISTENER_PID so the caller's SIGTERM
    # shutdown cannot later signal a stale pid that another process has since
    # inherited.
    #
    # BOUNDED, for the same reason the caller's success-path shutdown is — and
    # the reason matters MORE on this path, not less. This branch is reached
    # precisely when the process is alive but never answered /healthz, so a
    # bare `wait` after one SIGTERM is a hang on exactly the case the branch
    # exists to handle, in a script whose own header promises it "must never
    # hang or fail the run over an optional component". SIGKILL is the last
    # resort; this attempt produced no coverage data worth preserving, so
    # unlike the success path there is nothing lost by using it.
    kill "$LISTENER_PID" 2>/dev/null || true
    while [ "$_csl_waited" -lt 50 ]; do
        kill -0 "$LISTENER_PID" 2>/dev/null || break
        sleep 0.1
        _csl_waited=$((_csl_waited + 1))
    done
    if kill -0 "$LISTENER_PID" 2>/dev/null; then
        printf '[note] python-coverage — a failed listener attempt ignored SIGTERM; killing\n'
        kill -KILL "$LISTENER_PID" 2>/dev/null || true
    fi
    wait "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""
    return 1
}
