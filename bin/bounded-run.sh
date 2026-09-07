#!/usr/bin/env bash
# bounded_run — run a command under a wall-clock bound WITHOUT GNU coreutils.
#
# Sourced, not executed. Provides one function, `bounded_run`, with `timeout(1)`
# semantics on every host this repo targets — including base macOS, which ships
# no `timeout` and no `gtimeout` unless the user installed coreutils.
#
# WHY THIS EXISTS (#543). Callers used to write:
#
#     if command -v timeout >/dev/null 2>&1; then timeout N cmd; else cmd; fi
#
# which drops the bound on exactly the host most likely to need it: a bare macOS
# box with `uv` installed but no coreutils. The guard evaporated in the scenario
# it was written for. The other spelling — give up and skip when `timeout` is
# absent — is safe but costs the feature outright.
#
# The classic shell watchdog needs neither: background the command, background a
# killer that sleeps and then signals it, and race them.
#
# Exit status matches `timeout(1)`: the command's own status normally, or 124
# when the bound fired. 124 is reported from a MARKER FILE rather than inferred
# from the 128+SIGTERM wait status, because a command may legitimately die of
# SIGTERM from elsewhere and the two cases call for different handling.
#
# THREE non-obvious details, each of which broke a draft of this:
#
#   1. The watcher subshell MUST have stdout redirected away from the caller's.
#      When bounded_run is used inside a command substitution — `out="$(bounded_run
#      …)"` — the substitution does not return until every process holding the
#      pipe's write end has closed it. The watcher's `sleep` inherits that pipe,
#      so without the redirect a FAST command still blocks the caller for the
#      full bound. The bound would appear to work while making everything slow.
#
#   2. TERM then KILL, not KILL alone: a signal-handling child gets to clean up,
#      and a child that ignores TERM still cannot survive. Without the KILL
#      escalation the bound is advisory.
#
#   3. Killing the watcher does NOT kill the `sleep` it is blocked in — the
#      orphaned sleep lives out its remaining seconds. That is harmless (it holds
#      no descriptors once (1) is in place, and its target pid is gone) but it is
#      why the redirect in (1) is load-bearing rather than cosmetic.
#
#   4. THE BOUND MUST COVER THE CAPTURE, NOT ONLY THE PROCESS (#961). Note (1)
#      closes the WATCHER's hold on the caller's stdout. It says nothing about
#      the SUBJECT's descendants, and that is the hole: `"$@" &` inherits the
#      caller's stdout, which inside `out="$(bounded_run …)"` IS the command
#      substitution's pipe. Kill the subject and any grandchild it spawned still
#      holds that write end, so `$( )` blocks until the grandchild exits — even
#      though the process being bounded is already dead, and even though the
#      124-normalization below is sitting one line away, unreached.
#
#      Measured on PR #963's CI: a `--watch` case PASSed at 20:01:27 and the
#      next line appeared at 20:16:27 — fifteen minutes, on an idle GitHub
#      runner with no contention, ending in the job's timeout-minutes cap. The
#      holders were three `sleep 3600` watchdogs reparented to init, identified
#      by walking /proc/*/fd for the pipe's inode.
#
#      Note (3)'s "harmless" was therefore true of the watcher and false of the
#      system: this helper's OWN watchdog is a grandchild of exactly the shape
#      that hangs the capture. A comment asserting a safety property the code
#      does not have — which is the same defect #961 was filed about, one layer
#      down.
#
#      THE FIX: run the subject with its stdout/stderr on a TEMP FILE rather
#      than on the caller's descriptors, then relay the file after the wait. No
#      descendant ever holds the caller's pipe, so the substitution returns as
#      soon as bounded_run itself is done — whatever survives the signal.
#
#      NOT `setsid` + a process-group kill, which is the other obvious answer.
#      tests/validate-golem-watch.sh records that being tried and abandoned
#      (#397/#390): group-signalling from inside the suite is unreliable on a
#      headless runner, where the signal can land on run-all.sh itself and wedge
#      the whole job — trading this hang for a worse one. run-all.sh's own header
#      says the same about wrapping stages in `timeout`. Redirecting the capture
#      needs no signal topology at all, which is why it is the safe half of
#      #961's suggested direction.
#
#      The relay preserves interleaving of stdout and stderr (both land in one
#      file, in write order) but NOT their separation: a caller that redirects
#      the two streams differently sees both on stdout. Every caller in this
#      repo captures `2>&1`, so this is a no-op for them — but it is a real
#      contract change, stated here rather than discovered.
#
# bash-3.2 clean, per CLAUDE.md § Runtime policy.

# bounded_run SECONDS COMMAND [ARG...]
#   Runs COMMAND with the caller's stdin/stdout/stderr. Returns the command's
#   exit status, or 124 if SECONDS elapsed first.
bounded_run() {
    local secs="$1"
    shift
    [ "$#" -gt 0 ] || return 2

    # The marker lives in a private temp dir so concurrent bounded_run calls in
    # one shell cannot read each other's verdict.
    local mark_dir mark out rc=0 pid watcher
    mark_dir="$(command mktemp -d 2>/dev/null)" || return 2
    mark="$mark_dir/fired"
    out="$mark_dir/out"

    # See note (4). The subject's stdout/stderr go to a FILE, not to the
    # caller's descriptors, so no descendant of it can hold a command
    # substitution's pipe open past the bound. stdin is closed for the same
    # reason in reverse: a subject that inherits and blocks on the caller's
    # stdin is a second way to outlive the bound.
    "$@" >"$out" 2>&1 </dev/null &
    pid=$!

    # See note (1): the redirect is what keeps a fast command fast.
    (
        # `|| exit 0` is load-bearing, not defensive noise. If `sleep` is absent
        # or fails, it returns IMMEDIATELY — and without this guard the watcher
        # would fall straight through to mark-and-kill, so EVERY command would be
        # reported as timed out the instant it started. That is fail-CLOSED in
        # the worst way: a missing POSIX tool would turn every bounded call into
        # a spurious 124. Bailing out of the watcher instead degrades to
        # unbounded-but-correct, and bounded_run_available() below is how a
        # caller detects that condition up front rather than discovering it here.
        command sleep "$secs" || exit 0
        # Record the verdict BEFORE signalling, so the waiting parent can never
        # observe the death without the reason.
        : >"$mark"
        command kill -TERM "$pid" 2>/dev/null
        command sleep 2
        command kill -KILL "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    watcher=$!

    wait "$pid" 2>/dev/null || rc=$?

    command kill -TERM "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null || :

    [ -e "$mark" ] && rc=124

    # Relay what the subject wrote. AFTER the wait and the 124 verdict, so the
    # output is complete and the exit status is already decided — and `cat`
    # cannot block, because the file has no writer left that we care about.
    [ -s "$out" ] && command cat "$out"

    command rm -rf "$mark_dir" 2>/dev/null

    return "$rc"
}

# bounded_run_available — true when bounded_run can actually bound anything.
#
# It needs only `sleep`, `kill` and `mktemp`, all POSIX, so this is very nearly
# always true. It exists so callers can FAIL LOUD rather than degrade silently on
# the pathological host where it is not — the failure mode #543 is about.
bounded_run_available() {
    command -v sleep >/dev/null 2>&1 &&
        command -v mktemp >/dev/null 2>&1
}
