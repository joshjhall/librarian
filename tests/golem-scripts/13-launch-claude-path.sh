# shellcheck shell=bash
# golem-launch.sh — claude-on-the-session-PATH check (#1176), split out of
# 12-launch-auth.sh: these cases test check_session_claude_path, not auth
# delivery (#1192).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / ...) and sources tests/lib/golem-sandbox.sh (new_sandbox /
# run_launch_auth / plant_tmux_stub) BEFORE this file. This fragment only
# DEFINES test functions; the entry point dispatches them.

# --- claude on the session PATH (#1176) -------------------------------------
# The payload's `sh -c` sources no shell init, so the golem's PATH is the tmux
# server's global env (or, with no server, the launcher's). These cases re-enable
# the check run_launch_auth turns off, and drive it through the stub's
# show-environment knob, never a real server.

# _path_without_claude — the caller's PATH minus every dir holding a `claude`, so
# "missing" holds on a dev host too (CI has none to drop).
_path_without_claude() {
    local out="" d rest="$PATH:"
    while [ -n "$rest" ]; do
        d="${rest%%:*}"
        rest="${rest#*:}"
        [ -n "$d" ] && [ ! -x "$d/claude" ] && out="${out:+$out:}$d"
    done
    command printf '%s' "$out"
}

# _fake_claude_dir <sandbox> <name> — a dir holding an executable fake `claude`.
_fake_claude_dir() {
    command mkdir -p "$1/$2"
    command printf '%s\n' '#!/usr/bin/env sh' 'exit 0' >"$1/$2/claude"
    command chmod +x "$1/$2/claude"
}

# A running server whose PATH lacks claude warns, naming that server, even though
# the launcher's own PATH HAS claude — the server's value is what the golem gets.
test_launch_claude_path_server_env_missing_warns() {
    local sb
    new_sandbox sb
    _fake_claude_dir "$sb" fakebin
    command mkdir -p "$sb/srvbin"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$sb/bin:$sb/fakebin:$(_path_without_claude)" TMUX_STUB_SHOW_ENV="PATH=$sb/srvbin"
    assert_exit 0 "$RUN_RC" "warn-only: the launch still dispatches (exit 0)"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "new-session -d -s golem-7" \
        "and new-session is still reached"
    assert_contains "$RUN_OUT" "WARNING \`claude\` is not on the PATH golem-7 will inherit" \
        "a server PATH without claude is announced"
    assert_contains "$RUN_OUT" "running tmux server's global env" "naming the server env as the source"
    assert_contains "$RUN_OUT" "tmux set-environment -g PATH" "with the actionable fix"
    # stdout carries `started golem-N` for callers; the warning must stay off it.
    command rm -f "$sb/tmux-args.log"
    RUN_LAUNCH_STDERR="$sb/stderr.log" run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        GOLEM_SKIP_CLAUDE_PATH_CHECK= TMUX_STUB_SHOW_ENV="PATH=$sb/srvbin" \
        PATH="$sb/bin:$sb/fakebin:$(_path_without_claude)"
    assert_contains "$RUN_OUT" "started golem-7" "control: stdout still reports the start"
    assert_not_contains "$RUN_OUT" "is not on the PATH" "the warning never reaches stdout"
    assert_contains "$(command cat "$sb/stderr.log" 2>/dev/null)" "is not on the PATH" \
        "it goes to stderr instead"
}

# Control for the above: the same server shape with claude on its PATH is silent,
# even when the launcher's own PATH LACKS claude (server wins in both directions).
test_launch_claude_path_server_env_present_silent() {
    local sb
    new_sandbox sb
    _fake_claude_dir "$sb" srvbin
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$sb/bin:$(_path_without_claude)" TMUX_STUB_SHOW_ENV="PATH=$sb/srvbin"
    assert_exit 0 "$RUN_RC" "launch dispatches (exit 0)"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "show-environment -g PATH" \
        "control: the server PATH was actually probed"
    assert_not_contains "$RUN_OUT" "is not on the PATH" "a server PATH with claude raises no warning"
}

# No server (show-environment fails): the new-session would start one from the
# launcher's env, so the launcher's PATH decides — missing warns, present is silent.
test_launch_claude_path_no_server_uses_launcher_path() {
    local sb ctl
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$sb/bin:$(_path_without_claude)"
    assert_exit 0 "$RUN_RC" "warn-only with no server either (exit 0)"
    assert_contains "$RUN_OUT" "is not on the PATH golem-7 will inherit from the launcher's env" \
        "a launcher PATH without claude is announced, naming the launcher env"
    assert_contains "$RUN_OUT" "no tmux server answered" "labelled as no server, the exit-1 branch"
    assert_not_contains "$RUN_OUT" "has no global PATH" "not as a server lacking a global PATH"
    new_sandbox ctl
    _fake_claude_dir "$ctl" fakebin
    run_launch_auth "$ctl" OP_SECRETS_CACHE="$ctl/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$ctl/bin:$ctl/fakebin:$(_path_without_claude)"
    assert_exit 0 "$RUN_RC" "launch with claude on the launcher PATH dispatches"
    assert_not_contains "$RUN_OUT" "is not on the PATH" "and raises no warning"
}

# A server answering without a `PATH=` line (`-PATH`: unset in its global env)
# falls back to the launcher's PATH, and says so rather than claiming no server.
test_launch_claude_path_server_without_path_uses_launcher() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$sb/bin:$(_path_without_claude)" TMUX_STUB_SHOW_ENV="-PATH"
    assert_exit 0 "$RUN_RC" "launch dispatches (exit 0)"
    assert_contains "$RUN_OUT" "the running tmux server has no global PATH" \
        "names the launcher PATH as the source, not a missing server"
    assert_not_contains "$RUN_OUT" "no tmux server answered" "and does not claim no server answered"
}

# The probe touches tmux only once the worktree refusal has passed: a refused
# launch and `print` (tracks-runbook.sh's tmux-free contract) never probe, even with the
# check enabled — run_launch_auth's default skip would hide that. The refusal is
# the missing-worktree one, NOT the unwritable-TMPDIR auth refusal: there
# bounded_run cannot make its marker dir, so the probe could never reach tmux
# whatever the ordering, and the assertion would be vacuous.
test_launch_claude_path_never_probes_on_refusal_or_print() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        GOLEM_WORKTREE_DIR=no-such-worktrees
    assert_exit 2 "$RUN_RC" "control: the launch is refused (missing worktree)"
    assert_equals "" "$(command cat "$sb/tmux-args.log" 2>/dev/null)" \
        "a refused launch never probes tmux"
    new_sandbox sb
    plant_tmux_stub "$sb"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV HOME="$sb" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="${SANDBOX_TMUX_DIR:-$sb/.tmux}" TMUX_STUB_LOG="$sb/tmux-args.log" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_SKIP_CLAUDE_PATH_CHECK= \
            "$REAL_BASH" "$LAUNCH" print 7 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "control: print exits 0"
    assert_contains "$RUN_OUT" "tmux new-session" "control: print emitted the launch line"
    # Empty, not merely free of show-environment: the -V version probe (#1177)
    # belongs to launch too, so print must not run it either.
    assert_equals "" "$(command cat "$sb/tmux-args.log" 2>/dev/null)" \
        "print never probes tmux (no show-environment, no -V)"
}

# The probe runs BEFORE the 0600 token file is written, so its bounded window
# never extends the token's time on disk. The control proves the file IS written
# later in the same launch, so an empty snapshot is not just "no token".
test_launch_claude_path_probe_precedes_token_file() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        TMUX_STUB_SHOW_ENV="PATH=$sb/srvbin" TMUX_STUB_PROBE_TMP_LOG="$sb/probe-tmp.log" \
        ANTHROPIC_AUTH_TOKEN=sk-order-1176 # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "launch with a token dispatches (exit 0)"
    assert_true "[ -f '$sb/probe-tmp.log' ]" "control: the probe ran and snapshotted TMPDIR"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "golem-auth." \
        "control: the token file was written later in this launch"
    assert_not_contains "$(command cat "$sb/probe-tmp.log" 2>/dev/null)" "golem-auth." \
        "no token file exists yet when the tmux probe runs"
}

# GOLEM_SKIP_CLAUDE_PATH_CHECK=1 silences a case that would otherwise warn.
test_launch_claude_path_escape_hatch() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK=1 \
        PATH="$sb/bin:$(_path_without_claude)" TMUX_STUB_SHOW_ENV="PATH=$sb/nowhere"
    assert_exit 0 "$RUN_RC" "launch dispatches (exit 0)"
    assert_not_contains "$RUN_OUT" "is not on the PATH" "the escape hatch silences the warning"
    assert_not_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "show-environment" \
        "and skips the server probe entirely"
}

# --- probe shapes review left uncovered (#1192) -----------------------------

# A show-environment that never returns is cut off by the 5s bound: dispatch
# still completes, and the timeout (rc 124) takes the no-server branch, so the
# launcher's PATH decides. The stub sleeps 30s, so an unbounded probe blows the
# elapsed ceiling by a wide margin.
test_launch_claude_path_probe_hang_is_bounded() {
    local sb start elapsed
    new_sandbox sb
    start=$SECONDS
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$sb/bin:$(_path_without_claude)" TMUX_STUB_SHOW_ENV_MODE=hang
    elapsed=$((SECONDS - start))
    assert_exit 0 "$RUN_RC" "a hanging probe still dispatches (exit 0)"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "show-environment -g PATH" \
        "control: the hanging probe was actually reached"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "new-session -d -s golem-7" \
        "and new-session is reached after it"
    assert_true "[ $elapsed -lt 20 ]" "the probe is bounded (${elapsed}s, stub hangs 30s)"
    assert_contains "$RUN_OUT" "no tmux server answered" \
        "a timed-out probe is labelled as no server, the launcher PATH deciding"
}

# A server answering an empty `PATH=` hands the golem an EMPTY PATH — its value,
# not the launcher's — so claude cannot resolve and it warns, naming the server,
# even though the launcher's own PATH has claude.
test_launch_claude_path_server_empty_path_warns() {
    local sb
    new_sandbox sb
    _fake_claude_dir "$sb" fakebin
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$sb/bin:$sb/fakebin:$(_path_without_claude)" TMUX_STUB_SHOW_ENV="PATH="
    assert_exit 0 "$RUN_RC" "warn-only: the launch dispatches (exit 0)"
    assert_contains "$RUN_OUT" "is not on the PATH golem-7 will inherit from the running tmux server's global env" \
        "an empty server PATH warns, naming the server env, though the launcher has claude"
}

# A server that answers exit 0 with NO output is a live server with no PATH line:
# the launcher's PATH decides, labelled as a server lacking a global PATH — not as
# no server, which is the rc≠0 branch. The control proves the launcher PATH is
# what decides: with claude on it, the same silent server raises nothing.
test_launch_claude_path_server_silent_uses_launcher() {
    local sb ctl
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$sb/bin:$(_path_without_claude)" TMUX_STUB_SHOW_ENV_MODE=silent
    assert_exit 0 "$RUN_RC" "launch dispatches (exit 0)"
    assert_contains "$RUN_OUT" "the running tmux server has no global PATH" \
        "a silent server defers to the launcher PATH, labelled as a server without one"
    assert_not_contains "$RUN_OUT" "no tmux server answered" "and does not claim no server answered"
    new_sandbox ctl
    _fake_claude_dir "$ctl" fakebin
    run_launch_auth "$ctl" OP_SECRETS_CACHE="$ctl/no-such-cache" GOLEM_SKIP_CLAUDE_PATH_CHECK= \
        PATH="$ctl/bin:$ctl/fakebin:$(_path_without_claude)" TMUX_STUB_SHOW_ENV_MODE=silent
    assert_exit 0 "$RUN_RC" "control: launch with claude on the launcher PATH dispatches"
    assert_not_contains "$RUN_OUT" "is not on the PATH" "control: and raises no warning"
}
