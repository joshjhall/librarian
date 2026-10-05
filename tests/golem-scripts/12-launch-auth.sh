# shellcheck shell=bash
# golem-launch.sh — auth-token delivery (#244, #1153) and config-default env
# leak (#1125) tests, split out of 10-launch.sh (which outgrew its size budget).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / ...) and sources tests/lib/golem-sandbox.sh (new_sandbox /
# run_launch_auth / plant_tmux_stub) BEFORE this file. This fragment only
# DEFINES test functions; the entry point dispatches them.

# --- golem-launch.sh auth-token delivery (#244, #1153) ---------------------
# `launch` resolves ANTHROPIC_AUTH_TOKEN and hands it to the golem through a
# 0600 file the session command sources then deletes — never `tmux -e`, which
# left the token in the tmux server's argv (visible in ps) for its lifetime
# (#1153). To exercise the real dispatch (past the missing-worktree guard)
# without a real tmux server, each case prepends a `$sb/bin` stub `tmux` that
# logs its argv to $sb/tmux-args.log and exits 0, and creates the
# .worktrees/issue-N dir so the `[ -d ]` guard passes. Settings carry all rules
# so preflight is a silent no-op. ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL are
# explicitly --unset so the suite's own environment can never taint the
# resolution under test.

# _run_session_cmd <sandbox> — run the session command the tmux stub saved to
# $sb/session-cmd under `sh -c` (what tmux does), with a fake `claude` on PATH
# that records the ANTHROPIC_* values it was started with into
# $sb/claude-env.log. ANTHROPIC_* are unset, so anything recorded came from the
# token file, not the test's own env.
_run_session_cmd() {
    local sb="$1"
    command mkdir -p "$sb/fakebin"
    command printf '%s\n' '#!/usr/bin/env sh' \
        'printf "%s|%s\n" "${ANTHROPIC_AUTH_TOKEN:-}" "${ANTHROPIC_BASE_URL:-}" >>"$CLAUDE_ENV_LOG"' \
        >"$sb/fakebin/claude"
    command chmod +x "$sb/fakebin/claude"
    (cd "$sb" &&
        /usr/bin/env -uANTHROPIC_AUTH_TOKEN -uANTHROPIC_BASE_URL -uBASH_ENV -uENV \
            PATH="$sb/fakebin:$PATH" CLAUDE_ENV_LOG="$sb/claude-env.log" \
            sh -c "$(command cat "$sb/session-cmd")" >/dev/null 2>&1)
}

# A readable op-secrets cache with a token + base URL → both reach BOTH chained
# claude calls through the file; the token is in NO argv and NEVER echoed.
test_launch_auth_cache_injects_token() {
    local sb log authf
    new_sandbox sb
    command printf 'export ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244\nexport ANTHROPIC_BASE_URL=https://bifrost.example\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd"
    assert_exit 0 "$RUN_RC" "launch with a cache token dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    # Control: the stub really logged this dispatch, so the absences below
    # cannot pass on an empty log.
    assert_contains "$log" "new-session -d -s golem-7" "control: the tmux argv was logged"
    assert_not_contains "$log" "sk-secret-tok-244" "the token is in NO tmux argv (#1153)"
    assert_not_contains "$log" "ANTHROPIC_AUTH_TOKEN" "no -e ANTHROPIC_AUTH_TOKEN arg (#1153)"
    assert_contains "$log" "golem-auth." "the argv carries only the token file's path"
    assert_not_contains "$RUN_OUT" "sk-secret-tok-244" "the token is NEVER echoed to stdout/stderr"
    authf="$(command ls "$sb"/golem-auth.* 2>/dev/null | command head -n 1)"
    assert_not_empty "$authf" "the token file was written under TMPDIR"
    assert_equals "-rw-------" "$(command ls -l "$authf" 2>/dev/null | command cut -c1-10)" \
        "the token file is owner-only (0600)"
    _run_session_cmd "$sb"
    assert_equals "sk-secret-tok-244|https://bifrost.example
sk-secret-tok-244|https://bifrost.example" "$(command cat "$sb/claude-env.log" 2>/dev/null)" \
        "both chained claude calls receive the token and base URL"
    assert_equals "" "$(command ls "$sb"/golem-auth.* 2>/dev/null)" \
        "the session deletes the token file once sourced"
}

# The launcher's own ANTHROPIC_BASE_URL wins: the file carries the cache's
# token but NOT the cache's base URL, so the golem keeps the launcher's.
test_launch_auth_launcher_base_url_not_overridden() {
    local sb authf
    new_sandbox sb
    command printf 'export ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244\nexport ANTHROPIC_BASE_URL=https://cache.example\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" \
        ANTHROPIC_BASE_URL=https://launcher.example
    assert_exit 0 "$RUN_RC" "launch with a launcher base URL dispatches (exit 0)"
    authf="$(command ls "$sb"/golem-auth.* 2>/dev/null | command head -n 1)"
    # Positive control: the absence below cannot pass on a missing file.
    assert_not_empty "$authf" "the token file was written"
    # lint-allow-unanchored: per-run sandbox token file, no committed prose
    assert_file_contains "$authf" "ANTHROPIC_AUTH_TOKEN" "control: the token file carries the token"
    # lint-allow-unanchored: per-run sandbox token file, no committed prose
    assert_file_not_contains "$authf" "ANTHROPIC_BASE_URL" "the token file does not carry the cache base URL"
    _run_session_cmd "$sb"
    assert_equals "sk-secret-tok-244|" "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "the file delivers the token and leaves the base URL to the launcher env"
}

# _sh_quote itself, sliced out and driven directly over the shapes that break a
# naive quoter: leading/trailing/adjacent quotes, and an empty value. Each must
# round-trip through `sh` byte-for-byte — on the bash running this suite only.
# The quoter splits on `'` rather than using a ${v//…/…} replacement string,
# whose backslash/quote handling differs across bash 3.2 / 4.3 / 5.2 (#1153
# review); since CI runs bash 5 alone, the round-trips cannot prove that, so a
# structural assertion pins the replacement-free shape instead.
test_launch_sh_quote_round_trips_edge_shapes() {
    local fn v q back
    fn="$(command sed -n '/^_sh_quote() {/,/^}/p' "$LAUNCH")"
    assert_not_empty "$fn" "_sh_quote could be sliced out of golem-launch.sh (guards a vacuous pass)"
    # Comment lines precede the function, so the slice holds only its body.
    assert_not_contains "$fn" '//' "_sh_quote uses no \${v//…/…} replacement (bash-version-sensitive)"
    eval "$fn"
    for v in "plain" "a'b" "''" "'lead" "trail'" "a'b'c'' d" 'x$HOME y"z\w' ""; do
        q="$(_sh_quote "$v")"
        back="$(sh -c "printf '%s' $q")"
        assert_equals "$v" "$back" "_sh_quote round-trips [$v] through sh"
    done
}

# The token file is gone by the time the session starts (a tmp cleaner, a manual
# cleanup). Under a POSIX sh an unguarded `.` of a missing file EXITS the whole
# command, so both claude calls would be skipped and the golem would die with no
# session. Guarded, it must degrade to a tokenless start that still runs claude.
# Runs the session command under `sh` itself (dash on Debian/Ubuntu), the shell
# that exits — plain bash would continue either way and prove nothing.
test_launch_auth_missing_token_file_still_starts_claude() {
    local sb authf
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" \
        ANTHROPIC_AUTH_TOKEN=sk-vanished-1153 # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "launch dispatches (exit 0)"
    authf="$(command ls "$sb"/golem-auth.* 2>/dev/null | command head -n 1)"
    assert_not_empty "$authf" "control: a token file was written, so deleting it is meaningful"
    command rm -f "$authf"
    _run_session_cmd "$sb"
    assert_equals "|
|" "$(command cat "$sb/claude-env.log" 2>/dev/null)" \
        "both claude calls still run, tokenless, when the token file has vanished"
}

# A token carrying shell metacharacters round-trips byte-for-byte: the file is
# sourced by sh, so an unquoted `'` would break it and a `$` would expand.
test_launch_auth_token_quoting_round_trips() {
    local sb tok
    new_sandbox sb
    tok="sk-a'b\$HOME c\"d"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" \
        ANTHROPIC_AUTH_TOKEN="$tok"
    assert_exit 0 "$RUN_RC" "launch with a metachar token dispatches (exit 0)"
    _run_session_cmd "$sb"
    assert_equals "$tok|" "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "a token with quote, dollar, and space survives the file verbatim"
}

# A token the launcher INHERITED (resolution arm 1) is exported in its env, so
# without an un-export the server-starting new-session would freeze it into the
# tmux server's GLOBAL env (#1125's shape). It must reach neither argv nor the
# env tmux sees — and the golem still gets it, via the file.
test_launch_auth_inherited_token_not_in_tmux_env() {
    local sb envlog log
    new_sandbox sb
    envlog="$sb/tmux-env.log"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_ENV_LOG="$envlog" \
        TMUX_STUB_CMD_LOG="$sb/session-cmd" ANTHROPIC_AUTH_TOKEN=sk-inherited-1153 # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "launch with an inherited token dispatches (exit 0)"
    # lint-allow-unanchored: $envlog is a per-run env dump, no committed prose
    assert_file_contains "$envlog" "TMUX_STUB_LOG=$sb/tmux-args.log" \
        "control: the env log is this launch's tmux env"
    # lint-allow-unanchored: $envlog is a per-run env dump, no committed prose
    assert_file_not_contains "$envlog" "sk-inherited-1153" \
        "the inherited token never reaches the env tmux would freeze globally"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_not_contains "$log" "sk-inherited-1153" "the inherited token is in no tmux argv"
    _run_session_cmd "$sb"
    assert_equals "sk-inherited-1153|" "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "the golem still receives the inherited token via the file"
}

# A RELATIVE TMPDIR: the session sources the token file after tmux -c has moved
# it into the worktree, so the path must already be absolute. run_launch_auth
# cds into $sb, so TMPDIR=. lands the file there; the session command runs from
# the worktree (cd below) exactly as tmux -c would.
test_launch_auth_relative_tmpdir_path_is_absolute() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" \
        TMPDIR=. ANTHROPIC_AUTH_TOKEN=sk-relative-1153 # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "launch with a relative TMPDIR dispatches (exit 0)"
    # TMPDIR=. anchors as "$sb/./golem-auth.*" — absolute, under the sandbox.
    assert_contains "$(command cat "$sb/session-cmd" 2>/dev/null)" ". '$sb/" \
        "the session sources an ABSOLUTE token-file path"
    command mkdir -p "$sb/fakebin"
    command printf '%s\n' '#!/usr/bin/env sh' \
        'printf "%s|%s\n" "${ANTHROPIC_AUTH_TOKEN:-}" "${ANTHROPIC_BASE_URL:-}" >>"$CLAUDE_ENV_LOG"' \
        >"$sb/fakebin/claude"
    command chmod +x "$sb/fakebin/claude"
    (cd "$sb/.worktrees/issue-7" &&
        /usr/bin/env -uANTHROPIC_AUTH_TOKEN -uANTHROPIC_BASE_URL -uBASH_ENV -uENV \
            PATH="$sb/fakebin:$PATH" CLAUDE_ENV_LOG="$sb/claude-env.log" \
            sh -c "$(command cat "$sb/session-cmd")" >/dev/null 2>&1)
    assert_equals "sk-relative-1153|" "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "the golem receives the token when its shell starts in the worktree"
}

# The token file cannot be created → warn, dispatch tokenless, and NEVER fall
# back to putting the token in argv.
test_launch_auth_unwritable_tmpdir_never_falls_back_to_argv() {
    local sb log
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMPDIR="$sb/no-such-dir" \
        ANTHROPIC_AUTH_TOKEN=sk-nowhere-1153
    assert_exit 0 "$RUN_RC" "an unwritable token dir still dispatches (exit 0)"
    assert_contains "$RUN_OUT" "could not write a private token file" "warns that the token was not delivered"
    assert_not_contains "$RUN_OUT" "sk-nowhere-1153" "the warning does not echo the token"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "new-session -d -s golem-7" "control: the tmux argv was logged"
    assert_not_contains "$log" "sk-nowhere-1153" "no argv fallback for the token"
    assert_not_contains "$log" "golem-auth." "no token-file path when none was written"
}

# tmux new-session fails → the session never runs to delete the file, so the
# launcher removes it itself and exits 1 rather than claiming "started".
test_launch_auth_tmux_failure_removes_token_file() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_RC=1 \
        ANTHROPIC_AUTH_TOKEN=sk-orphan-1153 # gitleaks:allow (fake fixture token)
    assert_exit 1 "$RUN_RC" "a failed tmux new-session exits 1"
    assert_not_contains "$RUN_OUT" "started golem-7" "a failed dispatch does not claim it started"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "golem-auth." \
        "control: a token file was handed to tmux"
    assert_equals "" "$(command ls "$sb"/golem-auth.* 2>/dev/null)" \
        "the orphaned token file is removed"
}

# No cache, no op, no ref → no injection, no warning, exit 0. The dispatch is
# byte-identical to pre-#244 (only GOLEM_ID in the env args).
test_launch_auth_no_source_no_injection() {
    local sb log
    new_sandbox sb
    # Point the cache default at a nonexistent path so /dev/shm is never read.
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache"
    assert_exit 0 "$RUN_RC" "launch with no token source dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "new-session -d -s golem-7" "control: the tmux argv was logged"
    assert_not_contains "$log" "golem-auth." "no token file is handed to tmux when none resolves"
    assert_not_contains "$RUN_OUT" "WARNING" "no warning when there is no cache marker"
}

# `op read` hangs → the time-bounded wrapper kills it and dispatch still
# completes. A fake `op` that sleeps 60s stands in; OP_ANTHROPIC_AUTH_TOKEN_REF is
# set with no cache/env token, so resolution reaches the bounded op arm.
#
# NOT skipped on a coreutils-free host (#960). The guard here used to check for
# `timeout` or `gtimeout` and skip, on the stated grounds that "the arm no-ops
# there by design" — which stopped being true when #543 rewrote
# _bounded_op_read to use bounded_run specifically so the op probe would both
# run AND stay bounded on base macOS. The guard was therefore skipping the one
# host whose behaviour it was rewritten to fix, and its rationale asserted the
# opposite of what golem-launch.sh does.
test_launch_auth_op_hang_is_bounded() {
    local sb log
    new_sandbox sb
    command cat >"$sb/bin-op" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
    # op must be on the same PATH dir as the tmux stub; plant it there after
    # run_launch_auth creates bin/ — so pre-create bin/ and the op stub, then run.
    command mkdir -p "$sb/bin"
    command cp "$sb/bin-op" "$sb/bin/op"
    command chmod +x "$sb/bin/op"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        OP_ANTHROPIC_AUTH_TOKEN_REF="op://vault/anthropic/token"
    assert_exit 0 "$RUN_RC" "a hanging op read is bounded — dispatch still completes (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "new-session -d -s golem-7" "control: the tmux argv was logged"
    assert_not_contains "$log" "golem-auth." "a timed-out op read hands tmux no token file"
}

# A cache marker exists but yields no token → warn (don't fail), still dispatch,
# inject nothing. Exercises the elif warning arm.
test_launch_auth_cache_marker_no_token_warns() {
    local sb log
    new_sandbox sb
    # Cache is readable but exports something OTHER than the token.
    command printf 'export SOME_OTHER_SECRET=1\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache"
    assert_exit 0 "$RUN_RC" "an empty cache still dispatches (exit 0)"
    assert_contains "$RUN_OUT" "WARNING" "warns when a cache marker is present but no token resolves"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "new-session -d -s golem-7" "control: the tmux argv was logged"
    assert_not_contains "$log" "golem-auth." "no token file for an empty token"
}

# --- golem-launch.sh config-default env leak (#1125) -----------------------
#
# The `tmux new-session` that STARTS a server copies the client env into the
# server's global env, inherited by every later session. config.sh exports every
# knob it defaults, so a launch froze those defaults (the pre-#1056
# CONTEXT_BUDGET_FLOOR=91000) server-wide. The tmux stub dumps its own env to
# TMUX_STUB_ENV_LOG — the env a real tmux would have frozen. Run in a subshell
# with the knobs unset, because the suite's caller may itself carry the leak.

# Defaults config.sh merely filled in must NOT reach tmux.
test_launch_does_not_leak_config_defaults() {
    local sb envlog rc leaked
    new_sandbox sb
    envlog="$sb/tmux-env.log"
    (
        unset CONTEXT_BUDGET_FLOOR CONTEXT_BUDGET_THRESHOLD GOLEM_LEVEL
        run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_ENV_LOG="$envlog"
        command printf '%s' "$RUN_RC" >"$sb/rc"
    )
    rc="$(command cat "$sb/rc" 2>/dev/null || true)"
    assert_exit 0 "$rc" "launch dispatches (exit 0)"
    assert_file_exists "$envlog" "the tmux stub recorded its env"
    # Control: the dump carries this launch's own env, so the absences below
    # cannot pass on an empty or unrelated log. Only the knob lines are ever
    # read back — the dump is a whole env, and a failure must not echo it.
    # lint-allow-unanchored: $envlog is a per-run env dump, no committed prose
    assert_file_contains "$envlog" "TMUX_STUB_LOG=$sb/tmux-args.log" \
        "control: the env log is this launch's tmux env"
    leaked="$(command grep -E '^(CONTEXT_BUDGET_FLOOR|CONTEXT_BUDGET_THRESHOLD|GOLEM_LEVEL)=' "$envlog" || true)"
    assert_equals "" "$leaked" "config.sh's defaulted knobs are not handed to tmux"
}

# An operator override exported in the launcher's own env still propagates.
test_launch_keeps_operator_exported_override() {
    local sb envlog rc
    new_sandbox sb
    envlog="$sb/tmux-env.log"
    (
        unset CONTEXT_BUDGET_THRESHOLD
        run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_ENV_LOG="$envlog" \
            CONTEXT_BUDGET_FLOOR=12345
        command printf '%s' "$RUN_RC" >"$sb/rc"
    )
    rc="$(command cat "$sb/rc" 2>/dev/null || true)"
    assert_exit 0 "$rc" "launch dispatches (exit 0)"
    # lint-allow-unanchored: $envlog is a per-run env dump, no committed prose
    assert_file_contains "$envlog" "CONTEXT_BUDGET_FLOOR=12345" \
        "an operator-exported CONTEXT_BUDGET_FLOOR still reaches tmux"
}
