# shellcheck shell=bash
# workflow Python tools DRIVERS — python coverage invocations (issue #779).
#
# The `coverage run` driver blocks for the five shipped Python tools that are not
# named patterns.py, and so are not reached by the glob-driven loop in
# tests/coverage-python.sh:
#
#   ship-issue/sizing.py             the review-lens size scanner
#   ship-issue/plan-lens.py          the plan-lens projection scanner (#756)
#   ship-issue/split-verify.py       proves a decomposition lost nothing
#   scripts/autonomy-resolve.py      resolves L1-L4 + the critical cap
#   scripts/golem-event-listener.py  the orchestrate feed receiver
#
# WHY THIS FILE EXISTS. #748 added these drivers straight into the entry point,
# which had declared itself a THIN ENTRY POINT under the #564 split-suite
# contract — so the file grew past its shell budget while quoting the convention
# it was breaking. The fixtures went into a fragment; the ~370 lines of drivers
# did not. This is the other half of that move.
#
# THIS FRAGMENT IS SOURCED IN A DIFFERENT PHASE THAN THE FIXTURE FRAGMENTS, and
# that is the reason it is sourced from its own list rather than appended to the
# `10-…80-` one. Those build fixtures and must run BEFORE the glob driver loop;
# these are drivers and must run AFTER it, once COVERAGE_FILE is exported and the
# ports have been driven. Two phases, two source points — appending this file to
# the fixture list would run every invocation below before COVERAGE_FILE was set,
# scattering the data files outside WORKDIR where `combine` never sees them.
#
# Consumed from the entry point, which establishes ALL of these first:
#   WORKDIR / PLUGINS_DIR   paths
#   run_coverage            the resolved coverage runner (function, not a string)
#   exec_coverage           the exec'ing variant, for the backgrounded listener
#   run_count               the tally the final [ok] line reports
# plus the fixture path-list variables that tests/python-corpus/80-workflow-tools.sh
# exports. Under `set -u` an ordering mistake surfaces immediately as an unbound
# variable rather than as a silently smaller measurement.
#
# NOTE: nothing here asserts — coverage-python.sh is a Codecov driver, not a test
# suite. The behavioural gates for these tools are tests/validate-sizing-scanner.sh,
# tests/validate-plan-lens.sh, tests/validate-split-verify.sh,
# tests/validate-autonomy-resolve.sh and tests/validate-golem-event-listener.sh.
#
# tests/validate-coverage-corpus.sh's test_declared_tools_have_drivers searches
# THIS FILE as well as the entry point — a declared tool whose driver block is
# deleted from here must still fail that gate (#779 AC3, verified by mutation).

# --- The non-patterns.py workflow tools (#748) -------------------------------
# Each is declared in NON_PATTERNS_TOOLS above and driven here. Neither of the
# first two is file-list shaped in the way the glob loop assumes, which is
# exactly why they fell out of that loop in the first place: split-verify.py
# takes <original> <post-split> [results...] and autonomy-resolve.py takes
# subcommands. Driving them means writing their real CLI, not extending a glob.

# --- ship-issue/sizing.py — the review-lens size scanner ---------------------
SIZING_PY="$PLUGINS_DIR/workflow/skills/ship-issue/sizing.py"
if [ -f "$SIZING_PY" ]; then
    # Thresholds tuned down so the compact fixtures reach the over-budget and
    # classified-prose arms; the corpus stays small while the branches still fire.
    #
    # They are INLINE assignments on each invocation rather than an
    # `env $VARS run_coverage` prefix: `env` execs a BINARY and cannot invoke a
    # shell function, so that shape would fail every call — silently, since each
    # is `|| true`, leaving the driver looking fine while measuring nothing.

    # No numstat at all -> every over-threshold file reported LOW/informational.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    # BIG growth -> the crossed/blocking disposition.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" "$SIZING_NUMSTAT_BIG" >/dev/null 2>&1 || true
    # TRIVIAL growth -> the pre-existing-debt arm (a one-line touch is not this
    # PR's debt), the disposition that distinguishes this lens from the audit one.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" "$SIZING_NUMSTAT_TRIVIAL" >/dev/null 2>&1 || true
    # A numstat row matching nothing in the list -> the unmatched-row arm.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" "$SIZING_NUMSTAT_ORPHAN" >/dev/null 2>&1 || true
    # Default (untuned) thresholds -> the under-budget early-return path.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    # --measure mode: the 13-field metrics record plan-lens.py consumes.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        SKILL_WARN=40 SKILL_HIGH=80 DOC_WARN=30 DOC_HIGH=50 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" --measure "$SIZING_LIST" >/dev/null 2>&1 || true
    # Memory-bundle classification arms (index vs concept), and the opted-out
    # empty-root early return.
    MEMORY_BUNDLE_ROOT=".claude/memory" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    MEMORY_BUNDLE_ROOT='' \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    # Negative-path arms: usage (no argument), list-not-found (OSError), empty
    # list (early return), unreadable file (per-file OSError read arm).
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_NOFILE_LIST" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_EMPTY_LIST" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SIZING_PY" "$SIZING_UNREAD_LIST" >/dev/null 2>&1 || true
    run_count=$((run_count + 1))
fi

# --- ship-issue/plan-lens.py — the plan-lens projection scanner (#756) -------
PLANLENS_PY="$PLUGINS_DIR/workflow/skills/ship-issue/plan-lens.py"
if [ -f "$PLANLENS_PY" ]; then
    # The load-bearing arm: near.py is UNDER budget today and OVER once the
    # estimate lands. Both other lenses return early for it, so this projection
    # is the row only this scanner produces — driving it without an estimate that
    # CROSSES a budget would measure the file while missing its reason to exist.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        PLAN_HEADROOM_MIN_ESTIMATE=1 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" "$PLANLENS_EST_CROSS" >/dev/null 2>&1 || true
    # An estimate that leaves everything under -> the no-row arm.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        PLAN_HEADROOM_MIN_ESTIMATE=1 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" "$PLANLENS_EST_SMALL" >/dev/null 2>&1 || true
    # Malformed estimate rows -> the parse-skip arms.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        PLAN_HEADROOM_MIN_ESTIMATE=1 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" "$PLANLENS_EST_BAD" >/dev/null 2>&1 || true
    # No estimate sidecar at all -> the already-over-budget-only path.
    REVIEW_LOC_WARN=100 REVIEW_LOC_HIGH=200 AGENT_WARN=50 AGENT_HIGH=100 \
        PLAN_HEADROOM_MIN_ESTIMATE=1 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" >/dev/null 2>&1 || true
    # Below the minimum-estimate floor -> the too-small-to-report arm.
    PLAN_HEADROOM_MIN_ESTIMATE=9999 \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_LIST" "$PLANLENS_EST_CROSS" >/dev/null 2>&1 || true
    # Negative-path arms: usage, list-not-found, empty list.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_NOFILE_LIST" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$PLANLENS_PY" "$SIZING_EMPTY_LIST" >/dev/null 2>&1 || true
    run_count=$((run_count + 1))
fi

# --- ship-issue/split-verify.py — <original> <post-split> [results...] -------
SPLITV_PY="$PLUGINS_DIR/workflow/skills/ship-issue/split-verify.py"
if [ -f "$SPLITV_PY" ]; then
    # Sound split -> split-verified (all four properties hold).
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" "$SPLIT_KEPT" "$SPLIT_MOVED" >/dev/null 2>&1 || true
    # A unit dropped -> split-unit-lost (+ the LOC-conservation arm).
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" "$SPLIT_KEPT" "$SPLIT_LOSSY" >/dev/null 2>&1 || true
    # A call site left dangling -> split-fanin-dangling.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" "$SPLIT_DANGLE" >/dev/null 2>&1 || true
    # Markdown: heading moved out with NO link back -> split-heading-unreachable;
    # then the same split WITH the link -> the reachable arm.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_MD_ORIG" "$SPLIT_MD_KEPT_NOLINK" "$SPLIT_MD_MOVED" \
        >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_MD_ORIG" "$SPLIT_MD_KEPT_LINK" "$SPLIT_MD_MOVED" \
        >/dev/null 2>&1 || true
    # Memory bundle (#729): extracted concept with no index line ->
    # split-memory-orphan; then with MEMORY.md naming it -> the indexed arm.
    (cd "$SPLIT_MEM_ROOT" && MEMORY_BUNDLE_ROOT=".claude/memory" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_MEM_ORIG" "$SPLIT_MEM_KEPT" "$SPLIT_MEM_MOVED" \
        >/dev/null 2>&1) || true
    (cd "$SPLIT_MEM_ROOT" && MEMORY_BUNDLE_ROOT=".claude/memory" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_MEM_ORIG" "$SPLIT_MEM_KEPT" "$SPLIT_MEM_MOVED" \
        "$SPLIT_MEM_INDEX" >/dev/null 2>&1) || true
    # Negative-path arms: usage (none / one argument) and a named file that does
    # not exist, on both the original and the result side.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_GHOST" "$SPLIT_KEPT" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$SPLITV_PY" "$SPLIT_ORIG" "$SPLIT_GHOST" >/dev/null 2>&1 || true
    run_count=$((run_count + 1))
fi

# --- scripts/autonomy-resolve.py — subcommand shaped, not file-list shaped ---
AUTONOMY_PY="$PLUGINS_DIR/workflow/scripts/autonomy-resolve.py"
if [ -f "$AUTONOMY_PY" ]; then
    # `level`: each input route (a --level flag inside --from-args, a
    # --chosen-level from an orchestrator or the operator's setup answer, and no
    # signal at all -> the L1 fallback).
    for _lvl in 1 2 3 4; do
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" level --from-args "123 --level $_lvl" >/dev/null 2>&1 || true
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" level --chosen-level "$_lvl" >/dev/null 2>&1 || true
    done
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level >/dev/null 2>&1 || true
    # The severity/critical CAP (L4 -> L3, capped=true) in both label spellings,
    # and a non-critical severity that must NOT cap. This is the arm that decides
    # whether a plan gate is kept or auto-passed, so both sides are driven.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level --chosen-level 4 --severity critical >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level --chosen-level 4 --severity severity/critical >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level --chosen-level 4 --severity low >/dev/null 2>&1 || true
    # `gate`: routine vs escalation at every level, plus the --dead-end override
    # that defers to a human at L4 too.
    for _lvl in 1 2 3 4; do
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" gate routine --level "$_lvl" >/dev/null 2>&1 || true
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" gate escalation --level "$_lvl" >/dev/null 2>&1 || true
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" gate escalation --level "$_lvl" --dead-end >/dev/null 2>&1 || true
        # `sweep-interval` and `read` across the same level range.
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" sweep-interval --level "$_lvl" >/dev/null 2>&1 || true
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
            "$AUTONOMY_PY" read --state-level "$_lvl" >/dev/null 2>&1 || true
    done
    # `read` with no state level -> the L1 default.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" read >/dev/null 2>&1 || true
    # Usage-error arms (exit 2): no subcommand, unknown subcommand, unknown gate
    # kind, out-of-range level, non-numeric level, missing required flag.
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" bogus-subcommand >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" gate bogus-kind --level 2 >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" gate routine --level 9 >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" gate routine --level abc >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" gate routine >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" sweep-interval >/dev/null 2>&1 || true
    run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$AUTONOMY_PY" level --chosen-level 7 >/dev/null 2>&1 || true
    unset _lvl
    run_count=$((run_count + 1))
fi

# --- scripts/golem-event-listener.py — a BLOCKING HTTP server ----------------
#
# The one tool here that cannot simply be invoked and awaited: it binds a socket
# and calls serve_forever(). Three properties make driving it safe:
#
#   * EPHEMERAL PORT, WITH RETRY (#780). The OS hands out a free port (bind :0,
#     read it back, close) rather than the 8787 default, so a developer already
#     running a listener — or a second copy of this script — cannot collide.
#     Between that close and the real bind another process can still take the
#     port; `with_free_port` (tests/lib/free-port.sh) re-allocates and re-attempts
#     so a lost race costs a retry instead of this tool's whole measurement.
#     That mattered more here than in the behavioral gate: the gate FAILS a test
#     on a lost race, while this block prints a note and stays green with the
#     tool's line rate silently reduced.
#   * BOUNDED READINESS WAIT. /healthz is polled up to ~5s, bailing out early if
#     the process already died. It never waits on a server that will not arrive.
#   * SIGTERM SHUTDOWN. The listener installs a SIGTERM handler that raises
#     KeyboardInterrupt, so serve_forever() unwinds through its `finally` and the
#     process exits 0. That ordinary exit is what lets coverage.py FLUSH its data
#     file — a SIGKILL would leave the measurement it just collected unwritten,
#     which is the whole reason the shutdown path matters here.
#
# If the server does not come up, this block prints one line and moves on. A
# reporting script must never hang or fail the run over an optional component.
LISTENER_PY="$PLUGINS_DIR/workflow/scripts/golem-event-listener.py"
if [ -f "$LISTENER_PY" ]; then
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
    # `with_free_port 2 _cov_start_listener "$LISTENER_SB"` composes directly.
    _cov_start_listener() {
        _csl_sb="$1"
        _csl_port="$2"
        _csl_tries=0

        # `exec` inside the backgrounded subshell is load-bearing: without it,
        # $! is the SUBSHELL's pid, the SIGTERM below reaps only that wrapper,
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
        # past the readiness poll) and clear LISTENER_PID so the SIGTERM block
        # below cannot later signal a stale pid that another process has since
        # inherited.
        kill "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
        LISTENER_PID=""
        return 1
    }

    if with_free_port 2 _cov_start_listener "$LISTENER_SB"; then
        LISTEN_PORT="$FREE_PORT"

        # A valid event, an unknown event kind (defaults to "gate"), the
        # orphan sentinel (ACKed but never appended), a malformed body, an
        # oversized body (past GOLEM_EVENT_MAX_BODY), and a GET on /healthz.
        python3 - "$LISTEN_PORT" <<'PY' >/dev/null 2>&1 || true
import json, sys, urllib.error, urllib.request

port = sys.argv[1]
base = f"http://127.0.0.1:{port}"


def post(body: bytes, path: str = "/") -> None:
    req = urllib.request.Request(base + path, data=body, method="POST")
    try:
        urllib.request.urlopen(req, timeout=2).read()
    except urllib.error.HTTPError:
        pass  # 4xx arms are the point of several of these
    except OSError:
        pass


post(json.dumps({"golem": "golem-5", "event": "gate",
                 "message": "Claude needs your permission to push"}).encode())
post(json.dumps({"golem": "golem-7", "event": "escalation",
                 "message": "architectural decision"}).encode())
post(json.dumps({"golem": "golem-9"}).encode())            # absent event -> "gate"
post(json.dumps({"golem": "golem-?", "event": "gate",
                 "message": "orphan"}).encode())           # sentinel: ACK, no append
post(json.dumps({"golem": "golem-1", "event": "gate",
                 "message": "x" * 4096}).encode())         # oversized -> rejected
post(b"not json at all {{{")                                # malformed -> rejected
post(b"")                                                   # empty body
post(json.dumps([1, 2, 3]).encode())                        # non-object JSON
post(json.dumps({"golem": "golem-2", "event": "gate",
                 "message": "m"}).encode(), "/nope")        # unknown path
try:
    urllib.request.urlopen(base + "/healthz", timeout=2).read()
except OSError:
    pass
PY

        # SIGTERM (never SIGKILL first): the handler raises KeyboardInterrupt so
        # the process exits cleanly and coverage.py flushes its data file.
        #
        # The wait is BOUNDED. A bare `wait` would block forever if that handler
        # ever stopped firing (a future change swallowing the signal, a process
        # wedged in a syscall), and this job's only backstop is the 15-minute
        # workflow timeout — so a stuck listener would burn the whole budget and
        # report an unattributable job timeout instead of naming itself. SIGKILL
        # is the last resort: it loses this driver's coverage data, which is
        # strictly better than losing the entire run's.
        kill -TERM "$LISTENER_PID" 2>/dev/null || true
        _waited=0
        while [ "$_waited" -lt 50 ]; do
            kill -0 "$LISTENER_PID" 2>/dev/null || break
            sleep 0.1
            _waited=$((_waited + 1))
        done
        if kill -0 "$LISTENER_PID" 2>/dev/null; then
            printf '[note] python-coverage — golem-event-listener ignored SIGTERM; killing (its coverage data is lost)\n'
            kill -KILL "$LISTENER_PID" 2>/dev/null || true
        fi
        wait "$LISTENER_PID" 2>/dev/null || true

        # Count the tool as driven ONLY when the server actually served. The
        # printed `N ports run` is now a load-bearing signal (ci.yml defers to it
        # rather than restating a count), so incrementing on the did-not-start
        # path would inflate exactly the number that is supposed to be trustworthy.
        # This increment is now inside the SERVED branch, which is what makes that
        # true structurally rather than by a re-checked flag.
        run_count=$((run_count + 1))
        unset _waited _csl_sb _csl_port _csl_tries
    else
        # DEGRADED, NOT FATAL (#780 AC3): a reporting script must not fail the run
        # over an optional component — so this stays a note and the script goes on
        # to the fail-loud arms and the Cobertura emit. But it must stay VISIBLE,
        # and it now names the retry: "did not start" after two independent ports
        # is a broken listener, not a lost race, which is a materially different
        # diagnosis from the pre-#780 message.
        printf '[note] python-coverage — golem-event-listener did not start after 2 port attempts; skipping its driver\n'
        unset _csl_sb _csl_port _csl_tries
    fi

    # Fail-loud startup arms, driven WITHOUT binding anything: a non-integer port
    # and a non-integer max-body both exit 2 before the socket is created, and an
    # unbindable address exits 1. No cleanup needed — none of them starts a server.
    (cd "$LISTENER_SB" && GOLEM_EVENT_LISTEN_PORT="not-a-port" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$LISTENER_PY" >/dev/null 2>&1) || true
    (cd "$LISTENER_SB" && GOLEM_EVENT_MAX_BODY="not-a-number" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$LISTENER_PY" >/dev/null 2>&1) || true
    (cd "$LISTENER_SB" && GOLEM_EVENT_LISTEN_ADDR="256.256.256.256" \
        GOLEM_EVENT_LISTEN_PORT="8787" \
        run_coverage run --parallel-mode --source="$PLUGINS_DIR" \
        "$LISTENER_PY" >/dev/null 2>&1) || true
fi
