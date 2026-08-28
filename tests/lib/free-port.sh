# shellcheck shell=bash
# Ephemeral loopback port allocation, with retry (issue #780).
#
# THE RACE THIS EXISTS TO BOUND. The only portable way to get a free port is to
# bind `127.0.0.1:0`, read back what the OS assigned, and close — then hand the
# NUMBER to the process that will really bind it. Between that close and the real
# bind, any other process on the host can take the port. Classic
# bind-0-then-rebind TOCTOU. It cannot be eliminated without passing the live fd
# to the child (which the listener under test does not accept), so the remedy is
# to make a lost race RECOVERABLE rather than terminal.
#
# WHY THE RETRY WRAPS THE WHOLE ATTEMPT, NOT JUST THE ALLOCATION. A lost race is
# invisible at allocation time: `free_port` succeeds either way — it is the
# subsequent real bind that fails. So re-picking a port without re-running the
# thing that binds it would retry the half that never fails and fix nothing.
# `with_free_port` therefore takes the START as its callback, and one attempt
# means allocate + start + readiness-check as a unit.
#
# WHY IT IS SHARED. Two call sites allocated ports this way — the behavioral gate
# (tests/validate-golem-event-listener.sh) and the coverage driver
# (tests/python-corpus/90-workflow-tool-drivers.sh, #748, which copied the
# existing pattern rather than inventing it). They degrade DIFFERENTLY, and the
# asymmetry is the reason #780 was filed: the gate fails a test — loud,
# attributable, retryable — while the coverage driver prints one note, stays
# green, and the tool's measured line rate silently drops to whatever its
# import-time lines give. A quietly reduced coverage number is indistinguishable
# from a healthy one, which is the #748 lesson exactly. A third copy would
# reintroduce it, so tests/validate-free-port.sh asserts this file is the only
# home of the idiom.
#
# Sourced by ENTRY POINTS only (tests/validate-golem-event-listener.sh,
# tests/coverage-python.sh, tests/validate-cov-listener.sh) — never by a sourced
# fragment, per the #564 split-suite contract.
#
# Pure bash-3.2 + python3. `command`-prefixed tool calls per project convention.

# PORT_ATTEMPTS — how many allocate-and-start attempts a call site makes. ONE
# home, because the count is not just an argument: every diagnostic names it
# ("did not start after N port attempts"), across 8 message sites in two files
# (#825 item 2). Written independently, a bump to the call and a missed bump to a
# message leaves a diagnostic that MISREPORTS how many ports were really tried —
# and misreporting the attempt count is exactly what makes "did not start" read
# as a lost race instead of a broken listener. Every message interpolates this
# value with %s rather than restating it, so the two cannot diverge.
#
# Overridable from the environment for a flakier runner, which is the other
# reason it is a variable rather than a literal: raising it is one edit here, not
# a hunt through both suites.
#
# Read by the SOURCING suites, which shellcheck cannot see from here.
# shellcheck disable=SC2034
PORT_ATTEMPTS="${PORT_ATTEMPTS:-2}"

# FREE_PORT — set by with_free_port to the port whose attempt SUCCEEDED. Empty
# when every attempt failed, so a caller cannot mistake an exhausted retry for a
# usable port. Read by the SOURCING suite, which shellcheck cannot see from here.
# shellcheck disable=SC2034
FREE_PORT=""

# free_port — echo an ephemeral loopback port the OS hands out (bind :0, read it
# back, close). Returns non-zero and says why if no usable python3 is present.
#
# FAIL LOUD, never an empty echo: a caller that got "" would go on to start a
# server on the empty string and report a confusing downstream failure instead of
# the real cause. Same posture as the runtime version gates elsewhere in the repo.
free_port() {
    local port
    port="$(
        command python3 - <<'PY' 2>/dev/null
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
    )" || true

    if [ -z "$port" ]; then
        command printf 'free_port: could not allocate an ephemeral port (python3 missing or socket refused)\n' >&2
        return 1
    fi
    command printf '%s\n' "$port"
}

# with_free_port <attempts> <cmd> [args...] — allocate a port and run
# `<cmd> [args...] <port>`, retrying with a FRESH port when the attempt fails.
#
# The port is appended as the LAST argument, after the caller's leading args.
# That ordering is what lets both call sites pass their existing
# `<sandbox> <port>` starter unchanged — `with_free_port "$PORT_ATTEMPTS"
# start_listener "$dir"` composes with no wrapper closure, which matters because a closure would have to
# capture a dynamically-scoped local from the calling test function.
#
# `free_port` is called BY NAME, not inlined, so a test can shadow the allocator
# to hand out a port it has deliberately squatted. That seam is what makes a
# genuine contention fixture possible (tests/validate-free-port.sh) without
# adding a test-only hook to the code path under test.
#
# On success: sets FREE_PORT to the winning port, returns 0.
# On exhaustion: leaves FREE_PORT empty, returns 1. The caller decides whether
# that is fatal — the behavioral gate fails the test, the coverage driver notes
# it and moves on.
with_free_port() {
    local attempts="$1" cmd="$2"
    shift 2
    local n=0 port

    FREE_PORT=""

    # Validate SHAPE before value. `[ "$attempts" -lt 1 ]` on a non-numeric
    # argument is not false — it ERRORS (exit 2), which `if` then treats as
    # false, so a `[ ... ] -lt` guard alone lets an empty or non-numeric
    # `attempts` fall straight through to the loop, where the same comparison
    # errors on every iteration, the body never runs, and the function returns 1
    # with FREE_PORT empty and NO diagnostic. That is precisely the silent
    # failure the fail-loud posture above exists to prevent — the guard would
    # have been asserting an intent the code did not implement.
    case "$attempts" in
        '' | *[!0-9]*)
            command printf 'with_free_port: attempts must be a positive integer (got %s)\n' \
                "$attempts" >&2
            return 1
            ;;
    esac
    if [ "$attempts" -lt 1 ]; then
        command printf 'with_free_port: attempts must be >= 1 (got %s)\n' "$attempts" >&2
        return 1
    fi

    while [ "$n" -lt "$attempts" ]; do
        n=$((n + 1))
        # An allocation failure is a missing runtime, not a lost race — retrying
        # cannot help, so surface it immediately rather than burning the budget.
        port="$(free_port)" || return 1

        if "$cmd" "$@" "$port"; then
            FREE_PORT="$port"
            return 0
        fi
    done

    return 1
}
