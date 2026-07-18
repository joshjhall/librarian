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
#   4. a delivered SIGINT reaches cleanup_pane and reaps the pane worker — a
#      setsid-free behavioural assertion (`set -m` + `kill -INT -<pgid>`), gated on
#      a group-signal capability probe. See "Signal-delivery coverage" below.
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
# Case (3) is deterministic but purely textual — it never delivers a signal, so
# it cannot prove a real Ctrl-C *reaches* cleanup_pane and reaps the pane worker.
# Case (4) closes THAT gap behaviourally, setsid-free (issue #359):
#
#   4. a delivered SIGINT actually reaches cleanup_pane and reaps the pane worker.
#      golem-watch.sh runs under `set -m` so its backgrounded pipeline gets its own
#      process group, signallable via `kill -INT -<pgid>` WITHOUT `setsid` (the
#      target class CLAUDE.md calls out: base macOS, bare-Linux, musl images).
#
# The subtlety that makes case (4) meaningful rather than tautological: a group
# SIGINT hits every process in the group DIRECTLY, so a naive fake pane worker
# would die from the signal itself — reaped whether or not golem-watch's trap ran
# (verified: correct and no-trap variants both die). So the fake pane worker here
# **ignores INT** (`trap '' INT`): the direct group signal cannot kill it, and the
# ONLY remaining path to its death is cleanup_pane's `kill "$pane_pid"` (a
# SIGTERM). Its disappearance therefore PROVES cleanup_pane executed. The
# foreground `--stream` fake does NOT ignore INT and BLOCKS (a bounded sleep), so
# the group signal kills it, the foreground pipeline returns, and bash runs the
# (now un-deferred) trap — modelling the operator's Ctrl-C while the watcher is
# live. A no-trap regression leaves the INT-ignoring worker orphaned, which the
# poll detects; verified while authoring by reverting the trap to a bare `:`.
#
# Why case (4) does NOT subsume case (3): bash's EXIT arm ALSO runs on signal
# death, so the worker is reaped for BOTH `EXIT INT TERM` and an `EXIT`-only
# regression — a behavioural test cannot discriminate "dropped INT TERM" (that is
# case (3)'s exclusive job). Case (4) adds a DIFFERENT guarantee: that a delivered
# signal reaches cleanup at all (case (2) only fires the EXIT arm via natural
# foreground exit; a no-trap regression escapes it too).
#
# Case (4) SELF-GATES on a capability probe (`group_signal_unavailable`): it starts
# a `set -m` child in its own pgid and confirms `kill -INT -<pgid>` kills it. Where
# group-signal delivery is unreliable — the CI runner where the earlier prototype
# leaked orphans and the signal never landed — the test SKIPS honestly rather than
# flaking, so a green run on such a host is not mistaken for signal-path
# verification. A BOUNDED poll on the watcher's own death (not a blocking `wait`)
# guarantees the case can never wedge the suite even if a signal is swallowed — on
# timeout it force-reaps the group and reports the worker STILL ALIVE (a FAIL),
# never a false pass.
#
# Readiness polling (issue #360). The natural-exit path's fixed settle window is
# gone: make_stage's `--stream` fake now readiness-polls $PANE_WORKER_FILE (waits
# for the background pane worker to record its pid) before exiting, instead of a
# flat `sleep`, so CI resource contention cannot reorder the feed exit ahead of
# the pane worker coming up. The signal path (case 4) was already readiness-polled
# — run_watch_int_signal polls the worker file before delivering the SIGINT (#359),
# and make_stage_int's `--stream` fake deliberately BLOCKS (does not self-exit) so
# the group signal is what ends it. The remaining `sleep`s in the fakes are
# self-terminating stay-alive backstops (keep the worker present long enough to be
# observed / force-reaped), NOT settle windows.
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

# make_stage_int <varname>
# Like make_stage, but stages a fake tailored for the DELIVERED-SIGINT behavioural
# case (4), not the natural-exit case (2). Two deliberate differences from the fake
# above:
#   --stream-panes → `trap '' INT` so the pane worker IGNORES a delivered SIGINT.
#                    Case (4) sends a process-GROUP SIGINT, which hits every member
#                    directly; a fake that died from the signal itself would be
#                    reaped whether or not cleanup_pane ran (tautological). Ignoring
#                    INT leaves cleanup_pane's `kill "$pane_pid"` (a SIGTERM) as the
#                    ONLY thing that can end it, so the worker's disappearance
#                    PROVES the trap fired. Records $$ (the worker) as before.
#   --stream       → does NOT ignore INT and BLOCKS on a bounded sleep, so it is
#                    still alive when the group SIGINT arrives (the operator's
#                    Ctrl-C-while-watching scenario). The signal kills it, the
#                    foreground pipeline returns, and bash runs the trap. The sleep
#                    bound is a self-terminating backstop only — case (4) force-reaps
#                    the group after deciding the verdict.
make_stage_int() {
    local __out="$1" dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/gate.XXXXXX")" || return 1
    /usr/bin/cp "$WATCH" "$dir/golem-watch.sh"
    /usr/bin/cat >"$dir/golem-gate-watch.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --stream-panes)
        # Ignore INT so the DIRECT group signal cannot kill this worker — only
        # cleanup_pane's `kill` (SIGTERM) can. Its death then proves the trap ran.
        trap '' INT
        printf '%s\n' "$$" >"$PANE_WORKER_FILE"
        printf 'pane-line-1\n'
        sleep 30
        ;;
    --stream)
        # Block (do NOT ignore INT) so the foreground is live when the group SIGINT
        # lands: the signal ends this, the pipeline returns, bash runs the trap.
        printf 'feed-line-1\n'
        sleep 30
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

# group_signal_unavailable — capability probe for case (4). Returns 0 (→ SKIP) when
# this host cannot start a `set -m` child in its own process group and kill it with
# a group SIGINT. That is exactly the CI-runner condition that made the earlier
# behavioural prototype flake (the group signal never landed; the tree leaked as
# orphans), so gating on a live probe turns that flake into an honest skip.
#
# The probe backgrounds `sleep` under `set -m` (which puts it in a fresh process
# group whose pgid == its pid), confirms it IS its own group leader, group-signals
# it, and polls for death. A `set -m`/`set +m` toggle is local to this function and
# leaves the suite's job-control mode untouched.
group_signal_unavailable() {
    local child pgid n=0
    set -m
    (exec /usr/bin/sleep 30) &
    child=$!
    set +m
    pgid="$(/usr/bin/ps -o pgid= -p "$child" 2>/dev/null | /usr/bin/tr -d ' ')"
    if [ -z "$pgid" ] || [ "$pgid" != "$child" ]; then
        /usr/bin/kill "$child" 2>/dev/null || true
        return 0 # cannot isolate a group → unavailable
    fi
    /usr/bin/kill -INT -"$pgid" 2>/dev/null || true
    while [ "$n" -lt 40 ]; do
        if ! /usr/bin/kill -0 "$child" 2>/dev/null; then
            return 1 # signal landed and killed the group → AVAILABLE
        fi
        /usr/bin/sleep 0.05
        n=$((n + 1))
    done
    /usr/bin/kill -KILL "$child" 2>/dev/null || true
    return 0 # signal did not land in time → unavailable
}

# run_watch_int_signal <stage>
# Runs the case-(4) staged golem-watch.sh under `set -m` so its process tree gets
# its own group, DELIVERS a group SIGINT while the foreground is live, and reports
# whether the (INT-ignoring) pane worker was reaped. Sets WATCH_WORKER_PID and
# WATCH_WORKER_ALIVE ("0" reaped / "1" still alive). A BOUNDED poll on the watcher's
# death (not a blocking `wait`, and NO separate watchdog process) bounds the run so
# a swallowed signal can never wedge the suite — on timeout it reports the worker
# still alive (a FAIL), never a false pass. The whole `set -m` lifecycle runs in a
# stderr-discarded subshell so monitor mode's async job-control notice never leaks
# to the suite console; results cross back via a result file.
WATCH_WORKER_ALIVE=""
run_watch_int_signal() {
    local dir="$1"
    local worker_file="$dir/pane_worker" result_file="$dir/int_result"
    /usr/bin/rm -f "$worker_file" "$result_file"

    # The ENTIRE `set -m` monitored-job lifecycle (spawn in own group → signal →
    # reap) runs inside this subshell, whose stderr is discarded. Monitor mode
    # prints an async "Terminated" job-control notice when the group-signalled
    # watcher job is reaped; routed here it is swallowed rather than leaking to the
    # suite console. The subshell exports its observable results (worker pid,
    # whether it survived) through $result_file, so the caller still asserts on
    # real values. `set -m`/`set +m` are local to the subshell and never touch the
    # suite's job-control mode.
    (
        local watcher pgid worker alive dead tries=0
        set -m
        (
            cd "$dir" &&
                PANE_WORKER_FILE="$worker_file" exec "$REAL_BASH" "$dir/golem-watch.sh"
        ) >/dev/null 2>&1 &
        watcher=$!
        set +m

        pgid="$(/usr/bin/ps -o pgid= -p "$watcher" 2>/dev/null | /usr/bin/tr -d ' ')"

        # Readiness-poll for the recorded pane worker pid (no fixed startup sleep).
        while [ "$tries" -lt 100 ]; do
            [ -s "$worker_file" ] && break
            /usr/bin/sleep 0.02
            tries=$((tries + 1))
        done
        worker="$(/usr/bin/cat "$worker_file" 2>/dev/null || true)"

        # Deliver the operator's Ctrl-C: a group SIGINT while the foreground is live.
        /usr/bin/kill -INT -"$pgid" 2>/dev/null || true

        # BOUNDED poll for the watcher's own death instead of a blocking `wait` —
        # the built-in hang guard, with NO separate watchdog process. A watchdog
        # subshell doing `kill -KILL -<pgid>` cannot be used here: the pane worker
        # shares the watcher's pgid, so ANY group kill reaps it directly and would
        # mask a broken trap (a false pass). Here the group is force-killed ONLY
        # after `alive` has already been decided (cleanup below) or on a genuine
        # timeout — where the worker is reported STILL ALIVE (a FAIL), never a
        # false pass.
        dead=0
        tries=0
        while [ "$tries" -lt 250 ]; do
            if ! /usr/bin/kill -0 "$watcher" 2>/dev/null; then
                dead=1
                break
            fi
            /usr/bin/sleep 0.02
            tries=$((tries + 1))
        done
        if [ "$dead" -eq 0 ]; then
            # Signal was swallowed / foreground hung: force-reap the group and
            # report the worker as alive so the assertion FAILS loudly.
            /usr/bin/kill -KILL -"$pgid" 2>/dev/null || true
            /usr/bin/printf '%s 1\n' "$worker" >"$result_file"
            exit 0
        fi

        # Watcher is gone. Poll whether the INT-ignoring worker is gone too — its
        # death can only be cleanup_pane's SIGTERM (the group INT it ignores), so
        # "reaped" proves the trap fired.
        alive=1
        tries=0
        while [ "$tries" -lt 40 ]; do
            if ! /usr/bin/kill -0 "$worker" 2>/dev/null; then
                alive=0
                break
            fi
            /usr/bin/sleep 0.05
            tries=$((tries + 1))
        done
        # Belt-and-suspenders: reap the worker and force-kill the group AFTER
        # `alive` is decided, so the module cleanup does not have to chase a leak
        # and the verdict is never influenced by this teardown.
        /usr/bin/kill "$worker" 2>/dev/null || true
        /usr/bin/kill -KILL -"$pgid" 2>/dev/null || true

        /usr/bin/printf '%s %s\n' "$worker" "$alive" >"$result_file"
    ) 2>/dev/null

    # Import the subshell's results for the caller's assertions.
    WATCH_WORKER_PID="$(/usr/bin/awk '{print $1}' "$result_file" 2>/dev/null || true)"
    WATCH_WORKER_ALIVE="$(/usr/bin/awk '{print $2}' "$result_file" 2>/dev/null || true)"
}

# Behavioural signal-path assertion (issue #359). A DELIVERED group SIGINT must
# reach cleanup_pane and reap the pane worker. The fake pane worker ignores INT, so
# only cleanup_pane's SIGTERM can end it — its disappearance proves the trap fired
# on the delivered signal (not merely on a natural foreground exit as in case (2)).
# Setsid-free (`set -m` + `kill -INT -<pgid>`); self-gated on group_signal_unavailable.
test_delivered_int_reaps_pane_worker() {
    if group_signal_unavailable; then
        skip_test "group-signal delivery unavailable — behavioural INT signal-path coverage is best-effort (structural case 3 still guards the trap spec)"
        return
    fi
    local sb
    make_stage_int sb
    run_watch_int_signal "$sb"
    assert_not_empty "$WATCH_WORKER_PID" "the fake pane recorded its worker pid (\$\$)"
    assert_equals "0" "$WATCH_WORKER_ALIVE" \
        "a delivered SIGINT reaches cleanup_pane and reaps the INT-ignoring pane worker (setsid-free group signal)"
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

# Signal-delivery coverage (issue #254). Structural assertion that the cleanup
# trap stays armed on INT and TERM (not just EXIT) — deterministic and portable.
run_test test_trap_spec_arms_int_and_term "golem-watch: cleanup trap is armed on INT and TERM, not just EXIT (structural)"

# Signal-delivery coverage (issue #359). Setsid-free BEHAVIOURAL assertion that a
# delivered SIGINT reaches cleanup_pane and reaps the pane worker. Self-gates
# (SKIP) where group-signal delivery is unavailable. The fixed settle windows it
# and the natural-exit case relied on are now bounded readiness polls (#360).
run_test test_delivered_int_reaps_pane_worker "golem-watch: a delivered SIGINT reaches cleanup_pane and reaps the pane worker (behavioural, setsid-free)"

generate_report
