# shellcheck shell=bash
# golem-launch.sh — minimum tmux version check (#1177), split out of
# 12-launch-auth.sh: these cases test check_tmux_version, not auth delivery
# (#1201).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / ...) and sources tests/lib/golem-sandbox.sh (new_sandbox /
# run_launch_auth / plant_tmux_stub) BEFORE this file. This fragment only
# DEFINES test functions; the entry point dispatches them.

# --- minimum tmux version (#1177) -------------------------------------------
# The launch line passes `new-session -e`, which tmux added in 3.2 (2.9a and 3.1c,
# built from source, die with `unknown option -- e`). Driven through the stub's
# TMUX_STUB_VERSION knob; the default stub reports a supported 3.5a.

# Below the floor: refuse (exit 3) with the version, the floor and the fix — and
# before both new-session and the token file. The token makes the no-file
# assertion discriminating: without the refusal the file WOULD be written.
test_launch_tmux_version_below_floor_refuses() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_VERSION=3.1c \
        ANTHROPIC_AUTH_TOKEN=sk-floor-1177 # gitleaks:allow (fake fixture token)
    assert_exit 3 "$RUN_RC" "tmux 3.1c is refused (exit 3)"
    assert_contains "$RUN_OUT" "REFUSING golem-7" "the refusal names the golem"
    assert_contains "$RUN_OUT" "reports 'tmux 3.1c'" "and the version it found"
    assert_contains "$RUN_OUT" "needs tmux >= 3.2" "and the floor"
    assert_contains "$RUN_OUT" "Upgrade tmux" "with the remediation"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "-V" \
        "control: the version was actually probed"
    assert_not_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "new-session" \
        "new-session is never reached"
    assert_not_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "show-environment" \
        "nor the PATH probe, which runs after the version check"
    assert_equals "" "$(command ls "$sb" | command grep '^golem-auth\.' || true)" \
        "no token file is left behind"
}

# A MAJOR below 3 refuses too, whatever its minor: 2.9a must not pass on 9 >= 2.
test_launch_tmux_version_major_below_floor_refuses() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_VERSION=2.9a
    assert_exit 3 "$RUN_RC" "tmux 2.9a is refused (exit 3)"
    assert_contains "$RUN_OUT" "needs tmux >= 3.2" "naming the floor"
}

# The boundary itself, the `next-` dev spelling, and a two-digit minor (3.10
# must compare numerically, not as a string that sorts before 3.2) all dispatch.
test_launch_tmux_version_at_floor_dispatches() {
    local sb v
    for v in 3.2 3.10 next-3.6 4.0; do
        new_sandbox sb
        run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_VERSION="$v"
        assert_exit 0 "$RUN_RC" "tmux $v dispatches (exit 0)"
        assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "new-session -d -s golem-7" \
            "tmux $v reaches new-session"
        assert_not_contains "$RUN_OUT" "REFUSING" "tmux $v raises no refusal"
    done
}

# An unreadable version fails OPEN: an OpenBSD base tmux prints `openbsd-7.4`,
# and a `-V` that errors learned nothing. Both still dispatch.
test_launch_tmux_version_unreadable_fails_open() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_VERSION=openbsd-7.4
    assert_exit 0 "$RUN_RC" "an unparseable version dispatches (exit 0)"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "new-session -d -s golem-7" \
        "and reaches new-session"
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_VERSION_RC=1
    assert_exit 0 "$RUN_RC" "a failing tmux -V dispatches (exit 0)"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "new-session -d -s golem-7" \
        "and reaches new-session"
}

# A `-V` that never returns is cut off by the 5s bound and fails open like any
# other unreadable version (#1201). The stub sleeps 30s, so an unbounded probe
# blows the elapsed ceiling by a wide margin.
test_launch_tmux_version_hang_is_bounded() {
    local sb start elapsed
    new_sandbox sb
    start=$SECONDS
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_VERSION_MODE=hang
    elapsed=$((SECONDS - start))
    assert_exit 0 "$RUN_RC" "a hanging tmux -V still dispatches (exit 0)"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "-V" \
        "control: the hanging -V was actually reached"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "new-session -d -s golem-7" \
        "and new-session is reached after it"
    assert_not_contains "$RUN_OUT" "REFUSING" "a timed-out -V raises no refusal"
    assert_true "[ $elapsed -lt 20 ]" "the -V probe is bounded (${elapsed}s, stub hangs 30s)"
}
