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
    local mark_dir mark rc=0 pid watcher
    mark_dir="$(command mktemp -d 2>/dev/null)" || return 2
    mark="$mark_dir/fired"

    "$@" &
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
