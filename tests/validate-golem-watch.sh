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
# This gate pins two behaviours without a real streamer, tmux, or panes: it runs
# the REAL golem-watch.sh beside a FAKE golem-gate-watch.sh (resolved via the
# script's own `BASH_SOURCE` sibling lookup) inside a `mktemp -d`, and asserts:
#   1. both the `[feed]` and `[pane]` prefixes appear (both channels dispatched
#      and were prefixed distinctly);
#   2. after the foreground `--stream` exits, the REAL pane WORKER process
#      (`golem-gate-watch.sh --stream-panes`) is gone — the cleanup trap reaped
#      the whole pane pipeline, not just its subshell wrapper.
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
#   --stream       → sleeps briefly (so the background pane line reliably lands
#                    first), emits two lines, then exits — driving the foreground
#                    to return, which fires the cleanup trap in golem-watch.sh.
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
        sleep 1
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

# After the foreground --stream exits, the real pane WORKER
# (`golem-gate-watch.sh --stream-panes`) must be gone — reaped by the
# EXIT/INT/TERM trap tearing down the whole pane pipeline, not just its subshell
# wrapper. Poll the worker pid briefly so the assertion is not racy.
test_trap_kills_background_pane() {
    local sb
    make_stage sb
    run_watch "$sb"
    assert_not_empty "$WATCH_WORKER_PID" "the fake pane recorded its worker pid (\$\$)"
    local tries=0 alive=1
    while [ "$tries" -lt 10 ]; do
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

generate_report
