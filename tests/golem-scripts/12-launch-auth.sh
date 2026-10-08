# shellcheck shell=bash
# golem-launch.sh — auth-token delivery (#244, #1153) and config-default env
# leak (#1125) tests, split out of 10-launch.sh (which outgrew its size budget).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / AUTH / ...) and sources tests/lib/golem-sandbox.sh (new_sandbox /
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
# token file, not the test's own env. Extra VAR=value args are set in the
# session env AFTER the scrub — modelling what an already-running tmux server's
# GLOBAL env hands a new session (#1163).
_run_session_cmd() {
    local sb="$1"
    shift
    command mkdir -p "$sb/fakebin"
    command printf '%s\n' '#!/usr/bin/env sh' \
        'printf "%s|%s\n" "${ANTHROPIC_AUTH_TOKEN:-}" "${ANTHROPIC_BASE_URL:-}" >>"$CLAUDE_ENV_LOG"' \
        >"$sb/fakebin/claude"
    command chmod +x "$sb/fakebin/claude"
    (cd "$sb" &&
        /usr/bin/env -uANTHROPIC_AUTH_TOKEN -uANTHROPIC_BASE_URL -uBASH_ENV -uENV \
            PATH="$sb/fakebin:$PATH" CLAUDE_ENV_LOG="$sb/claude-env.log" "$@" \
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

# The launcher's own ANTHROPIC_BASE_URL wins over the cache's (#244) — and it
# rides in the token file, not the inherited env: an already-running tmux server
# hands the session its stale GLOBAL env, modelled here by a session-env URL
# the file must override (#1163).
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
    assert_file_contains "$authf" "https://launcher.example" "the token file carries the launcher's base URL"
    # lint-allow-unanchored: per-run sandbox token file, no committed prose
    assert_file_not_contains "$authf" "cache.example" "the token file does not carry the cache base URL"
    _run_session_cmd "$sb" ANTHROPIC_BASE_URL=https://stale.example
    assert_equals "sk-secret-tok-244|https://launcher.example
sk-secret-tok-244|https://launcher.example" "$(command cat "$sb/claude-env.log" 2>/dev/null)" \
        "both claude calls get the launcher's URL over a stale server-env one"
}

# Resolution arm 1 (token AND base URL inherited by the launcher, no cache): the
# URL used to be left to inheritance, which a running server breaks (#1163). It
# must reach the golem via the file over a stale session URL, never via argv.
test_launch_auth_inherited_base_url_survives_stale_server_env() {
    local sb log
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" \
        ANTHROPIC_AUTH_TOKEN=sk-inherited-1163 ANTHROPIC_BASE_URL=https://launcher.example # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "launch with an inherited token + base URL dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "new-session -d -s golem-7" "control: the tmux argv was logged"
    assert_not_contains "$log" "launcher.example" "the base URL is in no tmux argv"
    _run_session_cmd "$sb" ANTHROPIC_BASE_URL=https://stale.example
    assert_equals "sk-inherited-1163|https://launcher.example" \
        "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "the golem gets the launcher's URL, not the running server's stale one"
}

# The other two URL states (#1163 review). Cache-only: the cache's URL beats a
# stale server-env one — the original failure, reached from the cache arm — and
# an empty launcher URL does not shadow it. No
# URL anywhere: the file writes NO ANTHROPIC_BASE_URL line, so an empty export
# cannot clobber whatever URL the session env already carries.
test_launch_auth_base_url_cache_only_and_absent() {
    local sb authf
    new_sandbox sb
    command printf 'export ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244\nexport ANTHROPIC_BASE_URL=https://cache.example\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd"
    assert_exit 0 "$RUN_RC" "cache-only launch dispatches (exit 0)"
    _run_session_cmd "$sb" ANTHROPIC_BASE_URL=https://stale.example
    assert_equals "sk-secret-tok-244|https://cache.example" \
        "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "the cache's URL beats a running server's stale one"

    # A launcher URL that is SET but EMPTY counts as absent (`:-`), so the
    # cache's URL still wins over the stale server one.
    new_sandbox sb
    command printf 'export ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244\nexport ANTHROPIC_BASE_URL=https://cache.example\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" ANTHROPIC_BASE_URL=
    assert_exit 0 "$RUN_RC" "empty-launcher-URL launch dispatches (exit 0)"
    _run_session_cmd "$sb" ANTHROPIC_BASE_URL=https://stale.example
    assert_equals "sk-secret-tok-244|https://cache.example" \
        "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "an empty launcher URL falls back to the cache's"

    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" \
        ANTHROPIC_AUTH_TOKEN=sk-nourl-1163 # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "no-URL launch dispatches (exit 0)"
    authf="$(command ls "$sb"/golem-auth.* 2>/dev/null | command head -n 1)"
    # Positive control: the absence below cannot pass on a missing file.
    assert_not_empty "$authf" "control: the token file was written"
    # lint-allow-unanchored: per-run sandbox token file, no committed prose
    assert_file_not_contains "$authf" "ANTHROPIC_BASE_URL" "no URL known → no base-URL line in the file"
    _run_session_cmd "$sb" ANTHROPIC_BASE_URL=https://session.example
    assert_equals "sk-nourl-1163|https://session.example" \
        "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "the session's own URL is left untouched"
}

# A URL carrying shell metacharacters round-trips through the sourced file, and
# the no-token boundary is pinned: with a launcher URL but NO resolvable token
# no file is written, so nothing reaches argv. Delivering the URL there is
# #1170; this assertion is what that change must flip deliberately.
test_launch_auth_base_url_quoting_and_no_token_boundary() {
    local sb url log
    url="https://proxy.example/a?x=1&y='q' \$HOME"
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" \
        ANTHROPIC_AUTH_TOKEN=sk-quote-1163 ANTHROPIC_BASE_URL="$url" # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "metachar-URL launch dispatches (exit 0)"
    _run_session_cmd "$sb"
    assert_equals "sk-quote-1163|$url" "$(command head -n 1 "$sb/claude-env.log" 2>/dev/null)" \
        "a metachar base URL round-trips through the token file byte-for-byte"

    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_CMD_LOG="$sb/session-cmd" \
        ANTHROPIC_BASE_URL=https://launcher.example
    assert_exit 0 "$RUN_RC" "URL-only launch dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "new-session -d -s golem-7" "control: the tmux argv was logged"
    assert_not_contains "$log" "golem-auth." "no token → no auth file is sourced (#1170 boundary)"
    assert_equals "" "$(command ls "$sb"/golem-auth.* 2>/dev/null)" "no token → no auth file written"
}

# The auth helpers live in golem-auth.sh, which the launcher sources (#1162).
# Every behavioural case above drives them THROUGH the launcher, so they would
# still pass if a copy were re-inlined into golem-launch.sh and silently shadowed
# the sourced one — two copies free to drift. Pin the single home instead.
test_launch_sources_golem_auth() {
    local fn
    assert_file_contains "$LAUNCH" '^\. "\$SCRIPT_DIR/golem-auth\.sh"$' "golem-launch.sh sources golem-auth.sh"
    for fn in _bounded_op_read resolve_auth_token _sh_quote write_auth_file; do
        assert_not_empty "$(command grep -n "^$fn() {" "$AUTH")" "golem-auth.sh defines $fn (control)"
        assert_equals "" "$(command grep -n "^$fn() {" "$LAUNCH")" "golem-launch.sh does not redefine $fn"
    done
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
    fn="$(command sed -n '/^_sh_quote() {/,/^}/p' "$AUTH")"
    assert_not_empty "$fn" "_sh_quote could be sliced out of golem-auth.sh (guards a vacuous pass)"
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

# The session command reaches tmux as the three words `sh` `-c` `<payload>`,
# never as one string (#1159): tmux hands a one-string command to its
# default-shell, which comes from $SHELL and may be fish or csh. Asserted per
# ARG, since a joined argv log cannot tell `sh -c X` from the one string `sh -c X`.
test_launch_auth_payload_is_argv_sh_c() {
    local sb argv n
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_ARGV_LOG="$sb/argv.log" \
        ANTHROPIC_AUTH_TOKEN=sk-argv-1159 # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "launch dispatches (exit 0)"
    argv="$(command cat "$sb/argv.log" 2>/dev/null || true)"
    assert_contains "$argv" "golem-7" "control: the per-arg log is this launch's"
    n="$(command printf '%s\n' "$argv" | command wc -l)"
    n=$((n + 0))
    assert_equals "sh" "$(command printf '%s\n' "$argv" | command sed -n "$((n - 2))p")" \
        "the third-to-last tmux arg is exactly 'sh'"
    assert_equals "-c" "$(command printf '%s\n' "$argv" | command sed -n "$((n - 1))p")" \
        "the second-to-last tmux arg is exactly '-c'"
    assert_contains "$(command printf '%s\n' "$argv" | command sed -n "${n}p")" "[ -r '$sb/golem-auth." \
        "the last arg is the whole payload, opening with the token-file guard"
    assert_not_contains "$argv" "sk-argv-1159" "the token is still in no tmux arg (#1153)"
    # Same boundaries with NO token: the empty auth prefix leaves the payload
    # opening with `claude`, and it must still be argv `sh` `-c`, not one string.
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_ARGV_LOG="$sb/argv.log"
    assert_exit 0 "$RUN_RC" "a tokenless launch dispatches (exit 0)"
    argv="$(command cat "$sb/argv.log" 2>/dev/null || true)"
    n="$(command printf '%s\n' "$argv" | command wc -l)"
    n=$((n + 0))
    assert_equals "sh -c" "$(command printf '%s\n' "$argv" | command sed -n "$((n - 2))p;$((n - 1))p" | command tr '\n' ' ' | command sed 's/ $//')" \
        "tokenless: the two args before the payload are exactly 'sh' '-c'"
    assert_contains "$(command printf '%s\n' "$argv" | command sed -n "${n}p")" "claude --permission-mode auto '/workflow:next-issue 7" \
        "tokenless: the last arg is the whole payload, opening at claude"
}

# End to end against a REAL tmux with $SHELL pointing at a non-POSIX stand-in (a
# script that logs and fails, as fish/csh fail on `.`/`export`): the golem must
# still start WITH its token, and the stand-in must never run (#1159). Before
# the fix tmux ran the payload through that shell and the token never arrived.
test_launch_auth_non_posix_shell_still_delivers_token() {
    local sb i sock
    if ! command -v tmux >/dev/null 2>&1; then
        skip_test "tmux not installed (the default-shell path needs a real server)"
        return 0
    fi
    new_sandbox sb
    # Fail closed on isolation: tmux 3.5a reads a TMUX_TMPDIR that does NOT exist
    # as unset and falls back to the SHARED default server, where this launch
    # would land golem-7 and the cleanup below would kill every live golem.
    if [ -z "${SANDBOX_TMUX_DIR:-}" ] || [ ! -d "$SANDBOX_TMUX_DIR" ]; then
        assert_equals "an existing dir" "${SANDBOX_TMUX_DIR:-unset} (missing)" \
            "sandbox tmux dir exists before a real tmux runs"
        return 0
    fi
    command mkdir -p "$sb/fakebin"
    command printf '%s\n' '#!/usr/bin/env sh' \
        'printf "%s\n" "${ANTHROPIC_AUTH_TOKEN:-}" >>"$CLAUDE_ENV_LOG"' >"$sb/fakebin/claude"
    command printf '%s\n' '#!/usr/bin/env sh' 'printf "%s\n" "$*" >>"$BAD_SHELL_LOG"' 'exit 1' >"$sb/badshell"
    command chmod +x "$sb/fakebin/claude" "$sb/badshell"
    # PATH last wins over run_launch_auth's stub dir, so the REAL tmux runs.
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        SHELL="$sb/badshell" BAD_SHELL_LOG="$sb/badshell.log" CLAUDE_ENV_LOG="$sb/claude-env.log" \
        PATH="$sb/fakebin:$PATH" ANTHROPIC_AUTH_TOKEN=sk-shell-1159 # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "launch under a non-POSIX SHELL dispatches (exit 0)"
    # Bounded wait for both chained claude calls (~10s), never GNU timeout.
    i=0
    while [ "$i" -lt 100 ]; do
        [ "$(command wc -l 2>/dev/null <"$sb/claude-env.log" || echo 0)" -ge 2 ] && break
        command sleep 0.1
        i=$((i + 1))
    done
    # Clean up by explicit socket PATH (-S), never by TMUX/TMUX_TMPDIR: $TMUX
    # outranks TMUX_TMPDIR inside a golem, and a missing TMUX_TMPDIR falls back
    # to the shared server — either way kill-server would kill every live golem.
    # -S on a path with no socket errors instead of falling back.
    sock="$SANDBOX_TMUX_DIR/tmux-$(command id -u)/default"
    assert_equals "socket" "$([ -S "$sock" ] && echo socket || echo "none at $sock")" \
        "control: the launch's server is the sandbox socket, so cleanup reaches it"
    [ -S "$sock" ] && TMUX='' tmux -S "$sock" kill-server >/dev/null 2>&1 || true
    assert_equals "sk-shell-1159
sk-shell-1159" "$(command cat "$sb/claude-env.log" 2>/dev/null)" \
        "both claude calls receive the token despite a non-POSIX default-shell"
    assert_equals "" "$(command cat "$sb/badshell.log" 2>/dev/null)" \
        "the operator's default-shell never ran the session payload"
}

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
    assert_not_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "show-environment" \
        "print never probes tmux"
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

# A token resolved but its file cannot be created → REFUSE the launch (exit 3)
# before tmux runs, rather than dispatch a golem known to lack auth (#1160), and
# NEVER fall back to putting the token in argv (#1153). The in-function control
# runs the identical sandbox with a writable TMPDIR first, so "tmux was never
# invoked" cannot pass on a stub that simply never logs.
test_launch_auth_unwritable_tmpdir_refuses_launch() {
    local sb ctl log
    new_sandbox ctl
    run_launch_auth "$ctl" OP_SECRETS_CACHE="$ctl/no-such-cache" \
        ANTHROPIC_AUTH_TOKEN=sk-nowhere-1160 # gitleaks:allow (fake fixture token)
    assert_exit 0 "$RUN_RC" "control: a writable TMPDIR dispatches (exit 0)"
    assert_contains "$(command cat "$ctl/tmux-args.log" 2>/dev/null)" "new-session -d -s golem-7" \
        "control: the tmux stub logs a dispatch in this sandbox shape"
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMPDIR="$sb/no-such-dir" \
        ANTHROPIC_AUTH_TOKEN=sk-nowhere-1160 # gitleaks:allow (fake fixture token)
    assert_exit 3 "$RUN_RC" "an unwritable token dir with a resolved token refuses (exit 3)"
    assert_contains "$RUN_OUT" "REFUSING golem-7" "names the refused golem"
    assert_contains "$RUN_OUT" "TMPDIR" "points the operator at TMPDIR"
    assert_not_contains "$RUN_OUT" "started golem-7" "a refused launch does not claim it started"
    assert_not_contains "$RUN_OUT" "sk-nowhere-1160" "the refusal does not echo the token"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_equals "" "$log" "tmux is never invoked, so no session starts tokenless"
    assert_not_contains "$log" "sk-nowhere-1160" "no argv fallback for the token"
}

# The refusal is keyed on a RESOLVED token, not on TMPDIR alone: with the same
# unwritable TMPDIR and nothing to deliver, the launch still dispatches.
test_launch_auth_unwritable_tmpdir_without_token_still_dispatches() {
    local sb
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMPDIR="$sb/no-such-dir"
    assert_exit 0 "$RUN_RC" "no token + unwritable TMPDIR still dispatches (exit 0)"
    assert_not_contains "$RUN_OUT" "REFUSING" "nothing resolved, so nothing to refuse over"
    assert_contains "$(command cat "$sb/tmux-args.log" 2>/dev/null)" "new-session -d -s golem-7" \
        "the dispatch reaches tmux"
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

# _plant_chmod_stub <sandbox> <fail|readonly> — write $sb/bin/chmod, which
# run_launch_auth puts first on PATH. `command chmod` skips functions, not PATH,
# so write_auth_file runs the stub. It logs its argv to $sb/chmod.log, then:
# `fail` exits 1 (the chmod-600 arm); `readonly` makes the file 0400 with the
# REAL chmod and exits 0, so the following `>"$f"` write fails (the write arm).
_plant_chmod_stub() {
    local sb="$1" mode="$2" real
    real="$(command -v chmod)"
    command mkdir -p "$sb/bin"
    command printf '%s\n' '#!/usr/bin/env sh' \
        "printf '%s\\n' \"\$*\" >>'$sb/chmod.log'" >"$sb/bin/chmod"
    if [ "$mode" = readonly ]; then
        command printf '%s\n' "for f in \"\$@\"; do :; done" \
            "'$real' 400 \"\$f\"" 'exit 0' >>"$sb/bin/chmod"
    else
        command printf '%s\n' 'exit 1' >>"$sb/bin/chmod"
    fi
    command chmod +x "$sb/bin/chmod"
}

# _assert_refused_without_token_file <sandbox> <token> <arm> — the shared
# outcome of a write_auth_file failure arm: exit-3 refusal, the partial file
# removed, tmux never run, the token in neither output nor argv. The chmod.log
# control proves the stub ran on a real golem-auth.* file, so "no file left"
# cannot pass because the file was never created.
_assert_refused_without_token_file() {
    local sb="$1" token="$2" arm="$3" log
    assert_exit 3 "$RUN_RC" "$arm: a failed token-file write refuses (exit 3)"
    assert_contains "$RUN_OUT" "REFUSING golem-7" "$arm: names the refused golem"
    assert_contains "$(command cat "$sb/chmod.log" 2>/dev/null)" "600 $sb/golem-auth." \
        "$arm control: the stub ran on the created token file"
    assert_equals "" "$(command ls "$sb"/golem-auth.* 2>/dev/null)" \
        "$arm: the partial token file is removed"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_equals "" "$log" "$arm: tmux is never invoked"
    assert_not_contains "$RUN_OUT" "$token" "$arm: the refusal does not echo the token"
}

# write_auth_file's chmod-600 arm (#1161): the file exists, chmod fails, and the
# arm must remove it — the mktemp-failure test above never reaches this arm.
test_launch_auth_chmod_failure_removes_token_file() {
    local sb
    new_sandbox sb
    _plant_chmod_stub "$sb" fail
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        ANTHROPIC_AUTH_TOKEN=sk-chmodfail-1161 # gitleaks:allow (fake fixture token)
    _assert_refused_without_token_file "$sb" sk-chmodfail-1161 "chmod arm"
}

# write_auth_file's write arm (#1161): chmod succeeds but the file is left 0400,
# so the export lines cannot be written; the arm must remove the empty file.
test_launch_auth_write_failure_removes_token_file() {
    local sb
    if [ "$(command id -u)" = "0" ]; then
        skip_test "running as root — a 0400 file is still writable"
        return 0
    fi
    new_sandbox sb
    _plant_chmod_stub "$sb" readonly
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        ANTHROPIC_AUTH_TOKEN=sk-writefail-1161 # gitleaks:allow (fake fixture token)
    _assert_refused_without_token_file "$sb" sk-writefail-1161 "write arm"
}

# tmux new-session fails with NO token file (#1161): the `[ -n "$auth_file" ] &&`
# guard returns 1 here, and the arm must still report and exit 1 — never fall
# through to "started".
test_launch_auth_tmux_failure_without_token_exits_1() {
    local sb log
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" TMUX_STUB_RC=1
    assert_exit 1 "$RUN_RC" "a failed tokenless tmux new-session exits 1"
    assert_contains "$RUN_OUT" "tmux new-session failed for golem-7" "names the failed dispatch"
    assert_not_contains "$RUN_OUT" "started golem-7" "a failed dispatch does not claim it started"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "new-session -d -s golem-7" "control: tmux was invoked"
    assert_not_contains "$log" "golem-auth." "control: no token file was handed to tmux"
    assert_equals "" "$(command ls "$sb"/golem-auth.* 2>/dev/null)" "no token file is left"
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
