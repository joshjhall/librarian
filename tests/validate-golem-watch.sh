#!/usr/bin/env bash
# Smoke coverage for plugins/workflow/scripts/golem-watch.sh (issue #221), the
# PUSH streaming dispatcher for the golem gate channels, which had ZERO tests.
#
# golem-watch.sh streams two channels and prefixes each so the operator can tell
# them apart: the pane channel (`golem-gate-watch.sh --stream-panes`) runs in a
# background subshell piped through `sed 's/^/[pane] /'`, and the feed channel
# (`--stream`) runs in the FOREGROUND through `sed 's/^/[feed] /'`. A trap on
# EXIT/INT/TERM must tear down the whole background pane PIPELINE when the
# foreground stream returns, so a `Ctrl-C` (or a natural feed-stream exit) does
# not leave the pane watcher running.
#
# This gate pins several behaviours without a real streamer, tmux, or panes: it
# runs the REAL golem-watch.sh beside a FAKE golem-gate-watch.sh (resolved via the
# script's own `BASH_SOURCE` sibling lookup) inside a `mktemp -d`, and asserts:
#   1. both the `[feed]` and `[pane]` prefixes appear (both channels dispatched
#      and were prefixed distinctly);
#   2. after the foreground `--stream` exits, the REAL pane WORKER process
#      (`golem-gate-watch.sh --stream-panes`) is gone — the cleanup trap reaped
#      the whole pane pipeline, not just its subshell wrapper.
#   3. the trap is armed on INT/TERM (not only EXIT) — a structural assertion on
#      the trap spec. See "Signal-delivery coverage" below.
#
# Signal-delivery coverage (issue #254). Case (2) above drives the foreground fake
# to exit NATURALLY, which fires bash's EXIT arm of `trap cleanup_pane EXIT INT
# TERM` (golem-watch.sh) — it does NOT prove the INT/TERM arms are wired, even
# though Ctrl-C is the script's primary motivating scenario. A regression that
# dropped `INT TERM` (leaving bare `EXIT`) would sail past case (2). Case (3)
# closes that gap STRUCTURALLY — a grep asserting the real trap spec still lists
# both INT and TERM. That is deterministic and portable (runs on macOS bash 3.2),
# and it is in fact the STRONGEST guard available for the named regression:
# a *behavioural* signal test cannot catch "dropped INT TERM" at all, because —
# verified empirically on bash 5.2 — the EXIT arm ALSO runs when the shell dies
# from a real Ctrl-C (a process-GROUP signal), so a group signal reaps the worker
# even against the EXIT-only regression. (A behavioural TERM case is likewise
# impossible: the cleanup trap itself reaps via SIGTERM, so a worker rigged to
# survive a group TERM survives the trap too.)
#
# REMOVED — a former case (4) delivered a real SIGINT and asserted the pane worker
# was reaped (issues #359/#360). It was retired in #397/#390 as a net-negative:
#   * Marginal coverage. golem-watch.sh binds ONE handler to all three signals on
#     one line (`trap cleanup_pane EXIT INT TERM`). Case (2) already proves that
#     handler REAPS the pane behaviourally (via the EXIT arm); case (3) proves the
#     spec LISTS INT+TERM. There is no plausible bug where the shared one-line
#     handler fires on EXIT but not on INT — so a behavioural INT test adds almost
#     nothing over (2)+(3).
#   * High fragility. Faithfully modelling Ctrl-C requires a *process-group* SIGINT
#     (`kill -INT -<pgid>`), which requires isolating the watcher in its own group
#     via `set -m` job control. That job control is unreliable on a headless CI
#     runner (x86_64 ubuntu-latest): `set -m` can leave the watcher in the SUITE's
#     group, so the group SIGINT lands on run-all.sh itself and wedges the WHOLE
#     job to the 15-minute CI timeout. Every isolation workaround (setsid, a leader
#     pidfile, a per-PID descendant walk) traded one host/CI signal-topology
#     fragility for another. A test that can hang the suite it guards is not worth a
#     near-zero coverage delta over the deterministic (2)+(3).
# The structural case (3) remains the authoritative guard that the INT/TERM arms
# are wired.
#
# Readiness polling (issue #360). The natural-exit path's fixed settle window is
# gone: make_stage's `--stream` fake now readiness-polls $PANE_WORKER_FILE (waits
# for the background pane worker to record its pid) before exiting, instead of a
# flat `sleep`, so CI resource contention cannot reorder the feed exit ahead of
# the pane worker coming up. The remaining `sleep`s in the fakes are
# self-terminating stay-alive backstops (keep the worker present long enough to be
# observed), NOT settle windows.
#
# On (2): the subtlety this test exists to pin is that `pane_pid` (`$!` in
# golem-watch.sh) is the PID of the backgrounded `( "$watch" --stream-panes |
# sed )` SUBSHELL WRAPPER, NOT of the `golem-gate-watch.sh` worker running inside
# its pipeline. `kill "$pane_pid"` alone terminates only the wrapper and ORPHANS
# the worker — which the original assertion missed by polling `pane_pid` (the
# wrapper always dies promptly, so the test passed while the worker leaked). So
# the fake records its OWN pid (`$$`, the actual worker == what must be reaped)
# into a file; the test polls `kill -0 <worker_pid>` and asserts it is gone. A
# regression that reaps only the wrapper (or drops the trap) leaves that worker
# alive for its bounded pane sleep, which the poll window overlaps — verified
# while authoring by reverting the trap to a bare `kill "$pane_pid"` and watching
# this test flip to a failure.
#
# The dispatcher's output is redirected to a FILE (not captured via `$(...)`):
# a command substitution would block until the BACKGROUND pane worker also
# closed its stdout, i.e. until the fake's pane sleep finished — which would
# reap the worker before the poll ran and defeat the discrimination. A file
# redirect lets the run return the instant the foreground `bash` exits, while
# the (un-reaped) pane worker is still alive to be detected.
#
# Pure bash + coreutils; needs `timeout` (skips cleanly if absent) so a hung
# foreground can never wedge the suite. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCH="$REPO_ROOT/plugins/workflow/scripts/golem-watch.sh"

REAL_BASH="$(command -v bash)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "golem-watch.sh streaming dispatcher (#221)"

# Module-level scratch dir, cleaned up once when the suite exits. The RETURN-time
# pkill in run_watch is the primary reaper; this is the backstop.
WORKDIR="$(/usr/bin/mktemp -d)"
cleanup() {
    # Kill any fake pane process still sleeping, then drop the scratch dir. The
    # sandboxes are `mktemp -d "$WORKDIR/gate.XXXXXX"`, so their paths look like
    # `$WORKDIR/gate.aB12Cd/golem-gate-watch.sh` — match the `gate.` mktemp
    # prefix, NOT a literal `gate/` subdir (which never exists, so the old
    # pattern reaped nothing and let fakes leak on every run).
    /usr/bin/pkill -f "$WORKDIR/gate\..*/golem-gate-watch.sh" 2>/dev/null || true
    /usr/bin/rm -rf "$WORKDIR"
}
trap cleanup EXIT

# make_stage <varname>
# Lays out a staging dir with a copy of golem-watch.sh beside a FAKE
# golem-gate-watch.sh. golem-watch.sh resolves its sibling via BASH_SOURCE, so
# the copy must live next to the fake. The fake:
#   --stream-panes → records its OWN pid ($$, the real pane WORKER — the process
#                    the cleanup trap must reap) to pane_worker, emits one line,
#                    then sleeps a bounded time (self-terminates). The sleep keeps
#                    the worker alive long enough for the poll to observe whether
#                    the trap reaped it. Recording $$ (not $PPID, the subshell
#                    wrapper) is the whole point: the wrapper always dies promptly
#                    when the foreground exits, so asserting on it would pass even
#                    when the worker leaks.
#   --stream       → readiness-polls $PANE_WORKER_FILE (waits for the background
#                    pane worker to record its pid) BEFORE emitting two lines and
#                    exiting — the exit drives the foreground to return, which
#                    fires the cleanup trap in golem-watch.sh. Gating on the pid
#                    record (the readiness signal test_trap_kills_background_pane
#                    actually asserts on) means the feed never exits before the
#                    worker exists to be reaped. The poll replaces a flat settle
#                    sleep (#360) with that real readiness condition, so CI
#                    resource contention cannot race the feed exit ahead of the
#                    pane worker coming up.
# Assigns the staging dir to the caller's named variable.
make_stage() {
    local __out="$1" dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/gate.XXXXXX")" || return 1
    /usr/bin/cp "$WATCH" "$dir/golem-watch.sh"
    /usr/bin/cat >"$dir/golem-gate-watch.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --stream-panes)
        # $$ is THIS process — the real pane worker golem-watch pipes into sed.
        # The trap must reap it; $PPID (the ( ... | sed ) subshell wrapper) dies
        # on its own, so recording that instead would hide a worker leak.
        printf '%s\n' "$$" >"$PANE_WORKER_FILE"
        printf 'pane-line-1\n'
        sleep 5
        ;;
    --stream)
        # Readiness-poll for the pane worker's recorded pid instead of a flat
        # settle sleep (#360): only exit (firing the cleanup trap) once the pane
        # worker has written its pid to $PANE_WORKER_FILE, so the trap always has
        # a worker to reap regardless of pane-worker startup timing. The poll
        # ceiling (250 x 0.02s = 5s) sits well under run_watch's `timeout 10`
        # outer bound, leaving ample headroom for spawn + pipe + trap teardown;
        # the two bounds are intentionally compatible, not coincidentally close.
        tries=0
        while [ "$tries" -lt 250 ]; do
            [ -s "$PANE_WORKER_FILE" ] && break
            sleep 0.02
            tries=$((tries + 1))
        done
        printf 'feed-line-1\n'
        printf 'feed-line-2\n'
        ;;
esac
EOF
    /usr/bin/chmod +x "$dir/golem-gate-watch.sh"
    printf -v "$__out" '%s' "$dir"
}

# make_stage_starve <varname>
# Stages a fake that STARVES the readiness signal, to pin the feed fake's
# readiness poll as BOUNDED (issue #381, finding 2). Scope note: the readiness
# poll is a TEST-HARNESS mechanism introduced in PR #380 (#360) — it makes the
# feed fake wait for the pane worker to record its pid before exiting, so
# test_trap_kills_background_pane reliably has a worker to reap. Production
# golem-watch.sh has NO such poll. This case therefore guards the HARNESS pattern,
# not production: were a future edit to make the poll unbounded
# (`while [ ! -s "$f" ]` with no ceiling), a starved readiness signal would wedge
# the feed forever and hang the suite. Two differences from make_stage:
#   --stream-panes → NEVER writes $PANE_WORKER_FILE, so the readiness condition is
#                    never satisfied — the pane worker "comes up" but its pid
#                    record never appears.
#   --stream       → a bounded readiness poll like make_stage's, but with a
#                    DELIBERATELY SMALL ceiling (50 x 0.02s = 1s). Because
#                    $PANE_WORKER_FILE never fills, every iteration misses and the
#                    loop ALWAYS runs to the ceiling before falling through to emit
#                    the feed lines. The small ceiling is the point: it proves
#                    boundedness while leaving generous slack under run_watch's
#                    `timeout 10`. make_stage's happy-path fake usually breaks out
#                    of its poll almost immediately (the pane worker records its
#                    pid fast), but this starve path is always fully exhausted, so
#                    a 5s ceiling here would erode the timeout margin under CI load
#                    — 1s does not.
make_stage_starve() {
    local __out="$1" dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/gate.XXXXXX")" || return 1
    /usr/bin/cp "$WATCH" "$dir/golem-watch.sh"
    /usr/bin/cat >"$dir/golem-gate-watch.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --stream-panes)
        # Deliberately do NOT record a pid: starve the readiness signal so the
        # feed's poll runs to its bounded ceiling and falls through.
        printf 'pane-line-1\n'
        sleep 5
        ;;
    --stream)
        # Bounded readiness poll like make_stage's fake, with a small ceiling
        # (50 x 0.02s = 1s). $PANE_WORKER_FILE never fills, so this always exhausts
        # the ceiling and falls through to emit the feed lines — the bounded
        # timeout/starvation path finding 2 pins, with ample margin under the
        # `timeout 10` outer bound.
        tries=0
        while [ "$tries" -lt 50 ]; do
            [ -s "$PANE_WORKER_FILE" ] && break
            sleep 0.02
            tries=$((tries + 1))
        done
        printf 'feed-line-1\n'
        printf 'feed-line-2\n'
        ;;
esac
EOF
    /usr/bin/chmod +x "$dir/golem-gate-watch.sh"
    printf -v "$__out" '%s' "$dir"
}

# Results of the most recent run.
WATCH_OUT=""
WATCH_WORKER_PID=""

# run_watch <stage>
# Runs the staged golem-watch.sh under `timeout` so a regressed foreground can
# never wedge the suite. Output is redirected to a FILE, NOT captured via
# `$(...)`: command substitution would block until the background pane worker
# closed its stdout too (i.e. until the fake's pane sleep ended), reaping the
# worker before the trap check could observe it. The file redirect returns the
# instant the foreground `bash` exits. WATCH_OUT gets the combined output;
# WATCH_WORKER_PID gets the recorded pane WORKER pid (the real
# `golem-gate-watch.sh --stream-panes` process the trap must reap).
run_watch() {
    local dir="$1"
    local worker_file="$dir/pane_worker" out_file="$dir/out"
    /usr/bin/rm -f "$worker_file" "$out_file"
    (
        cd "$dir" &&
            PANE_WORKER_FILE="$worker_file" \
                /usr/bin/timeout 10 "$REAL_BASH" "$dir/golem-watch.sh"
    ) >"$out_file" 2>&1 || true
    WATCH_OUT="$(/usr/bin/cat "$out_file" 2>/dev/null || true)"
    WATCH_WORKER_PID="$(/usr/bin/cat "$worker_file" 2>/dev/null || true)"
}

# Both channels dispatched and were prefixed distinctly.
test_both_channels_prefixed() {
    local sb
    make_stage sb
    run_watch "$sb"
    assert_contains "$WATCH_OUT" "[feed] feed-line-1" "the feed channel is streamed with a [feed] prefix"
    assert_contains "$WATCH_OUT" "[pane] pane-line-1" "the pane channel is streamed with a [pane] prefix"
}

# Why there is no stdout channel-ORDERING assertion (issue #381, finding 1).
# One might expect `[pane] pane-line-1` to precede `[feed] feed-line-1` in
# WATCH_OUT, since the readiness poll makes the feed wait for the pane worker's
# recorded pid before exiting. It does not, and asserting it would be flaky:
# golem-watch.sh runs the pane channel backgrounded through its OWN `sed -u` and
# the feed channel foreground through a SEPARATE `sed -u` (golem-watch.sh:22,34),
# both writing the same redirected file. The readiness poll gates on the pane
# worker recording its PID (make_stage's --stream-panes writes $PANE_WORKER_FILE
# *before* printing `pane-line-1`), NOT on that line reaching stdout — the two
# `sed` pipelines then race to the shared file with no ordering guarantee. So the
# only real invariant here is pid-file readiness, which test_trap_kills_background_pane
# below already asserts (assert_not_empty "$WATCH_WORKER_PID"); a `grep -n`
# line-order check would pin a non-invariant and flake under load. Left
# deliberately unasserted.

# After the foreground --stream exits, the real pane WORKER
# (`golem-gate-watch.sh --stream-panes`) must be gone — reaped by the
# EXIT/INT/TERM trap tearing down the whole pane pipeline, not just its subshell
# wrapper. Poll the worker pid briefly so the assertion is not racy.
test_trap_kills_background_pane() {
    local sb
    make_stage sb
    run_watch "$sb"
    assert_not_empty "$WATCH_WORKER_PID" "the fake pane recorded its worker pid (\$\$)"
    # Event-based poll: it breaks the instant the worker dies, so the happy path
    # pays no fixed wall time — only a genuine trap regression spends the window.
    # Bound it generously (50 x 0.2s = 10s) so CI contention that merely delays
    # the trap's SIGTERM never false-fails; a real leak still fails once elapsed.
    local tries=0 alive=1
    while [ "$tries" -lt 50 ]; do
        if /usr/bin/kill -0 "$WATCH_WORKER_PID" 2>/dev/null; then
            /usr/bin/sleep 0.2
        else
            alive=0
            break
        fi
        tries=$((tries + 1))
    done
    assert_equals "0" "$alive" \
        "the pane worker (golem-gate-watch.sh --stream-panes) is gone after the foreground exits (trap reaped the pipeline)"
}

# Readiness-poll starvation/fallthrough (issue #381, finding 2). When the pane
# worker never records its pid, the feed fake's readiness poll must run to its
# ceiling and STILL emit — proving that poll is BOUNDED. Scope: the poll is a
# TEST-HARNESS readiness mechanism (make_stage / make_stage_starve fakes, PR #380),
# NOT production golem-watch.sh; this case guards the harness pattern so a future
# edit that made the poll unbounded (`while [ ! -s "$f" ]` with no ceiling) would
# hang the suite here rather than silently reintroduce the #360 startup race that
# the poll was added to close. make_stage_starve stages the starvation: its
# --stream-panes arm writes no $PANE_WORKER_FILE, so the readiness signal never
# fires; an unbounded poll would then wedge the feed forever, run_watch's
# `timeout 10` would fire, `[feed]` would never appear, and the first assertion
# below would fail loudly.
test_starvation_poll_falls_through_bounded() {
    local sb
    make_stage_starve sb
    run_watch "$sb"
    # The feed still emits after the poll exhausts its ceiling — the fallthrough
    # ran and the foreground did not wedge (the run returned before `timeout 10`).
    assert_contains "$WATCH_OUT" "[feed] feed-line-1" \
        "the feed channel still streams after the readiness poll exhausts its bounded ceiling (starvation fallthrough)"
    # And it fell through BECAUSE readiness was starved: the worker recorded no
    # pid, so run_watch read an empty worker file. This pins the test to the
    # starvation path rather than a coincidental fast pane-worker startup.
    assert_equals "" "$WATCH_WORKER_PID" \
        "the starved pane worker recorded no pid (readiness signal never fired)"
}

# --- Signal-delivery coverage (issue #254) ----------------------------------

# Structural trap-spec assertion. The real golem-watch.sh cleanup trap must stay
# armed on BOTH INT and TERM, not only EXIT — Ctrl-C (SIGINT) is the script's
# primary motivating scenario, and a regression that dropped `INT TERM` would
# leave case (2) above (which fires only the EXIT arm) still green. Assert the
# actual trap line arms both signals. Portable and timing-free — runs everywhere,
# including macOS bash 3.2.
test_trap_spec_arms_int_and_term() {
    assert_true \
        "/usr/bin/grep -Eq '^[[:space:]]*trap[[:space:]]+cleanup_pane([[:space:]]+[A-Z]+)*[[:space:]]+INT([[:space:]]+[A-Z]+)*([[:space:]]+[A-Z]+)*\$' '$WATCH' && /usr/bin/grep -Eq '^[[:space:]]*trap[[:space:]]+cleanup_pane([[:space:]]+[A-Z]+)*[[:space:]]+TERM([[:space:]]+[A-Z]+)*\$' '$WATCH'" \
        "golem-watch.sh arms its cleanup trap on INT and TERM (not just EXIT)"
}

# --- Run all tests ----------------------------------------------------------

# The suite needs `timeout` to bound the foreground stream. Gate it from inside a
# run_test body so the counters stay consistent.
timeout_unavailable() { ! command -v timeout >/dev/null 2>&1; }

test_timeout_available() {
    if timeout_unavailable; then
        skip_test "timeout not available — cannot bound the streaming dispatcher"
        return
    fi
    assert_true "command -v timeout" "timeout is available to bound the foreground stream"
}

run_test test_timeout_available "timeout is available (suite prerequisite)"

if timeout_unavailable; then
    generate_report
    exit $?
fi

run_test test_both_channels_prefixed "golem-watch: both feed + pane channels are streamed and prefixed"
run_test test_trap_kills_background_pane "golem-watch: the cleanup trap kills the background pane on foreground exit"

# Readiness-poll starvation coverage (issue #381). The feed's bounded poll must
# fall through and still emit when the pane worker never records its pid — pinning
# the poll's ceiling so a regression to an unbounded wait fails loudly.
run_test test_starvation_poll_falls_through_bounded "golem-watch: the readiness poll falls through (bounded) when the pane worker never signals readiness"

# Signal-delivery coverage (issue #254). Structural assertion that the cleanup
# trap stays armed on INT and TERM (not just EXIT) — deterministic and portable.
run_test test_trap_spec_arms_int_and_term "golem-watch: cleanup trap is armed on INT and TERM, not just EXIT (structural)"

generate_report
