# shellcheck shell=bash
# golem-launch.sh — golem helper-script tests (issue #564 split).
#
# Covers argument validation, print/dispatch, autonomy-level threading (#301), the version-skew guard (#230), and auth-token injection (#244).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- golem-launch.sh --------------------------------------------------------

# No subcommand → usage error, exit 2.
test_launch_no_arg_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH"
    assert_exit 2 "$RUN_RC" "golem-launch with no subcommand exits 2"
    assert_contains "$RUN_OUT" "Usage" "prints a usage message"
}

# Unknown subcommand → usage error, exit 2.
test_launch_bad_subcommand_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" frobnicate
    assert_exit 2 "$RUN_RC" "golem-launch with an unknown subcommand exits 2"
    assert_contains "$RUN_OUT" "Usage" "prints a usage message"
}

# `print <N>` with a valid number → emits a single bare `tmux new-session` line
# (matching the Bash(tmux new-session:*) allow rule) naming golem-N, exit 0.
test_launch_print_emits_new_session() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5
    assert_exit 0 "$RUN_RC" "print <N> exits 0"
    assert_contains "$RUN_OUT" "tmux new-session" "print emits a tmux new-session line"
    assert_contains "$RUN_OUT" "golem-5" "the line targets golem-5"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5" "the line resumes the issue's namespaced next-issue run"
    # Pin the namespaced form: the pre-#230 regression emitted a bare
    # "'/next-issue" (the exact string the active plugin rejects as Unknown
    # command). Assert it never reappears — the ' before it disambiguates from
    # the "workflow:next-issue" substring, which also contains "next-issue".
    assert_not_contains "$RUN_OUT" "'/next-issue" "never emits the bare (un-namespaced) /next-issue"
    assert_not_contains "$RUN_OUT" "'/ship-issue" "never emits the bare (un-namespaced) /ship-issue"
}

# OPERATOR-FACING STDERR must namespace its slash-commands too (#584).
#
# The assertions above cover the LAUNCH LINE. The two refusal messages — the
# tmux-permission wall and the version-skew refusal — are a different surface
# with the same footgun: text a human reads and then TYPES. A bare `/orchestrate`
# does not resolve as installed, so an operator following the remediation
# literally types a command that fails.
#
# tests/lint-command-refs.sh cannot catch these: its corpus is markdown only.
#
# Asserted against the SOURCE rather than by driving both refusals, because each
# needs a distinct hostile precondition (no tmux rules in either settings scope;
# a version-skewed install registry) and this pins the property directly. The
# regex targets a bare `/orchestrate` NOT preceded by `workflow:` — matching the
# namespaced form would make the assertion tautological.
test_launcher_stderr_namespaces_orchestrate() {
    assert_true "! command grep -nE '(^|[^:])/orchestrate' '$LAUNCH' | command grep -v '^[0-9]*: *#'" \
        "no operator-facing bare /orchestrate in golem-launch.sh (#584)"

    # NON-VACUITY: the namespaced form must actually be present, or a file that
    # simply dropped both messages would satisfy the assertion above.
    assert_true "[ \"\$(command grep -c '/workflow:orchestrate' '$LAUNCH')\" -ge 2 ]" \
        "both refusal messages carry the namespaced /workflow:orchestrate"
}

# `print` with a non-numeric argument → exit 2.
test_launch_print_non_numeric_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print abc
    assert_exit 2 "$RUN_RC" "print with a non-numeric issue exits 2"
    assert_contains "$RUN_OUT" "issue number" "explains an issue number is required"
}

# --- golem-launch.sh autonomy-level threading (#301) ------------------------
# golem-launch.sh must carry the operator's CHOSEN level into the launch line's
# `/workflow:next-issue <N> --level M`, not a hardcoded 4. Exercised on the pure
# `print` path (no real tmux). The default (no flag, no env) stays 4 so a bare
# call is byte-identical to the pre-#301 behavior.

# `print <N> --level 3` emits `--level 3` and NEVER the old hardcoded `--level 4`.
test_launch_print_level_flag_substituted() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5 --level 3
    assert_exit 0 "$RUN_RC" "print <N> --level 3 exits 0"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5 --level 3" \
        "the launch line carries the chosen level 3"
    assert_not_contains "$RUN_OUT" "--level 4" \
        "the hardcoded --level 4 no longer appears when a level is passed"
}

# `print <N>` with no flag and no env → the documented default `--level 4`.
test_launch_print_level_defaults_to_4() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5
    assert_exit 0 "$RUN_RC" "print <N> with no level exits 0"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5 --level 4" \
        "an omitted level defaults to 4 (unchanged pre-#301 shape)"
}

# `GOLEM_LEVEL=2 print <N>` (no flag) → the env fallback wins → `--level 2`.
test_launch_print_level_env_fallback() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_LEVEL=2 \
            "$REAL_BASH" "$LAUNCH" print 5 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "GOLEM_LEVEL=2 print <N> exits 0"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5 --level 2" \
        "GOLEM_LEVEL is the env fallback when no --level flag is given"
}

# An explicit `--level` flag beats the `GOLEM_LEVEL` env fallback.
test_launch_print_level_flag_beats_env() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_LEVEL=2 \
            "$REAL_BASH" "$LAUNCH" print 5 --level 1 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "print <N> --level 1 with GOLEM_LEVEL=2 exits 0"
    assert_contains "$RUN_OUT" "/workflow:next-issue 5 --level 1" \
        "the --level flag overrides the GOLEM_LEVEL env"
}

# `print <N> --level 9` (out of range) → exit 2 with an actionable message.
test_launch_print_level_out_of_range_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5 --level 9
    assert_exit 2 "$RUN_RC" "print <N> --level 9 exits 2"
    assert_contains "$RUN_OUT" "--level must be" "explains the valid level range"
}

# `print <N> --level` with no value → exit 2 (fail loud, no silent default).
test_launch_print_level_missing_value_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5 --level
    assert_exit 2 "$RUN_RC" "print <N> --level with no value exits 2"
    assert_contains "$RUN_OUT" "--level needs a value" "explains a value is required"
}

# GOLEM_MODEL unset → NO `--model` in the emitted line (byte-identical to the
# pre-knob launch shape — the #487 no-regression invariant).
test_launch_print_model_unset_omits_flag() {
    local sb
    new_sandbox sb
    run_in "$sb" "$LAUNCH" print 5
    assert_exit 0 "$RUN_RC" "print <N> with GOLEM_MODEL unset exits 0"
    assert_not_contains "$RUN_OUT" "--model" \
        "an unset GOLEM_MODEL emits no --model (byte-identical launch line)"
}

# `GOLEM_MODEL=sonnet print <N>` → ` --model "sonnet"` spliced after BOTH the
# next-issue and ship-issue `claude` calls (#487).
test_launch_print_model_set_both_claude_calls() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_MODEL=sonnet \
            "$REAL_BASH" "$LAUNCH" print 5 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "GOLEM_MODEL=sonnet print <N> exits 0"
    # Both claude invocations must carry the model — guard against injecting only
    # one. next-issue call:
    assert_contains "$RUN_OUT" "claude --model \"sonnet\" --permission-mode auto '/workflow:next-issue 5" \
        "GOLEM_MODEL splices --model into the next-issue claude call"
    # ship-issue call:
    assert_contains "$RUN_OUT" "claude --model \"sonnet\" --permission-mode auto '/workflow:ship-issue'" \
        "GOLEM_MODEL splices --model into the ship-issue claude call"
}

# GOLEM_MODEL reaches the REAL `launch` tmux dispatch path (not just `print`).
# `launch_line()` (print) and the `launch` case splice golem_model_flag()
# independently, so cover the dispatch argv the tmux stub captures too (#487).
test_launch_dispatch_model_both_claude_calls() {
    local sb log
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" GOLEM_MODEL=sonnet
    assert_exit 0 "$RUN_RC" "launch with GOLEM_MODEL=sonnet dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "claude --model \"sonnet\" --permission-mode auto '/workflow:next-issue 7" \
        "GOLEM_MODEL reaches the real dispatch next-issue claude call"
    assert_contains "$log" "claude --model \"sonnet\" --permission-mode auto '/workflow:ship-issue'" \
        "GOLEM_MODEL reaches the real dispatch ship-issue claude call"
}

# INJECTION SAFETY (#487): a GOLEM_MODEL carrying shell-metacharacters must be
# neutralized — golem_model_flag() backslash-escapes `"`/backtick/`$`/`\` so the
# value cannot break out of the double-quoted `--model "…"` word that tmux runs
# via `sh -c`. A malicious value like `x"; touch pwned; echo "` must appear
# ESCAPED in the dispatch argv, and its injected `; touch pwned` must NOT run as
# a standalone statement (the `\"` keeps it inside the quoted model token).
test_launch_dispatch_model_shell_metachars_escaped() {
    local sb log
    new_sandbox sb
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/no-such-cache" \
        'GOLEM_MODEL=x"; touch pwned; echo "'
    assert_exit 0 "$RUN_RC" "launch with a metachar GOLEM_MODEL still dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    # The embedded double quotes are backslash-escaped in the emitted argv, so the
    # value stays one --model token rather than breaking out into new statements.
    assert_contains "$log" 'claude --model "x\"; touch pwned; echo \""' \
        "embedded quotes in GOLEM_MODEL are escaped, not left to break the quoting"
    # And the stub never let the injected command run: no 'pwned' file is created.
    if [ -e "$sb/pwned" ] || [ -e "$sb/.worktrees/issue-7/pwned" ]; then
        assert_contains "MARKER-CREATED" "MARKER-ABSENT" \
            "GOLEM_MODEL injection created a file — escaping failed"
    else
        assert_contains "ok" "ok" "no injected file created (escaping holds)"
    fi
}

# `launch <N>` when the worktree is absent → exit 2 with a remediation pointing
# at worktree-new.sh. Stops BEFORE any real `tmux new-session` (no worktree, so
# the dir guard fires first). Stub both settings scopes at in-sandbox paths so
# preflight reads no real ~/.claude/settings.json.
test_launch_missing_worktree_exits_2() {
    local sb
    new_sandbox sb
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "launch with a missing worktree exits 2"
    assert_contains "$RUN_OUT" "worktree" "names the missing worktree"
    assert_contains "$RUN_OUT" "worktree-new.sh" "points at worktree-new.sh for remediation"
}

# preflight with a project settings file containing ALL required rules → exit 0
# and reports the permissions are present. jq-gated.
test_launch_preflight_rules_present_exits_0() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (settings_has_rules no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/proj-settings.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(tmux new-session:*)",
      "Bash(tmux ls:*)",
      "Bash(tmux kill-session:*)"
    ]
  }
}
EOF
    command printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" preflight 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "preflight with all rules present exits 0"
    assert_contains "$RUN_OUT" "present" "reports the launch permissions are present"
}

# preflight with rules MISSING in both scopes → exit 3 with an actionable
# remediation listing the rules to add. jq-gated.
test_launch_preflight_rules_missing_exits_3() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (settings_has_rules no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # Project file present but with only TWO of the three required rules.
    command cat >"$sb/proj-settings.json" <<'EOF'
{ "permissions": { "allow": ["Bash(tmux new-session:*)", "Bash(tmux ls:*)"] } }
EOF
    command printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" preflight 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "preflight with a missing rule exits 3"
    assert_contains "$RUN_OUT" "NOT authorized" "surfaces the unauthorized state"
    assert_contains "$RUN_OUT" "Bash(tmux kill-session:*)" "lists the rules to add"
}

# --- golem-launch.sh version-skew guard (#230) ------------------------------
# The running helper's plugin version is read from the repo's real
# plugins/workflow/.claude-plugin/plugin.json; tests fabricate the ACTIVE-install
# version via CLAUDE_INSTALLED_PLUGINS to force the equal / differ branches
# without touching the operator's real ~/.claude install.

# The name+version this running golem-launch.sh belongs to (its sibling
# manifest). jq-gated at the call site; here it seeds the fabricated registry.
PLUGIN_MANIFEST="$REPO_ROOT/plugins/workflow/.claude-plugin/plugin.json"

# write_installed_plugins <path> <version> — fabricate an installed_plugins.json
# whose workflow@librarian record carries <version>.
write_installed_plugins() {
    command cat >"$1" <<EOF
{ "plugins": { "workflow@librarian": [ { "version": "$2" } ] } }
EOF
}

# launch with the active install version EQUAL to the running version → the skew
# guard passes silently; the run falls through to its normal missing-worktree
# exit 2 (no worktree in the sandbox). Proves a matched version never blocks.
test_launch_version_match_passes() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (version guard no-ops without jq)"
        return 0
    fi
    local sb ver
    new_sandbox sb
    ver="$(jq -r '.version' "$PLUGIN_MANIFEST")"
    write_installed_plugins "$sb/installed.json" "$ver"
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_INSTALLED_PLUGINS="$sb/installed.json" \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "matched version passes the guard, reaches missing-worktree exit 2"
    assert_not_contains "$RUN_OUT" "version skew" "no skew message when versions agree"
}

# launch with the active install version DIFFERING from the running version →
# the guard REFUSES with exit 3 and an actionable message naming both versions,
# BEFORE any tmux side effect (worktree absence never reached).
test_launch_version_skew_refuses_exit_3() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (version guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_installed_plugins "$sb/installed.json" "0.0.1-stale"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_INSTALLED_PLUGINS="$sb/installed.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "version skew refuses dispatch with exit 3"
    assert_contains "$RUN_OUT" "version skew" "surfaces the skew"
    assert_contains "$RUN_OUT" "0.0.1-stale" "names the active install version"
    assert_contains "$RUN_OUT" "REFUSING" "refuses rather than dispatching a wedged golem"
}

# GOLEM_SKIP_VERSION_CHECK=1 with a differing version → the refusal downgrades to
# a warning and the run PROCEEDS past the guard (reaching missing-worktree exit
# 2). Proves the escape hatch for legitimate mid-release / worktree dispatch.
test_launch_version_skew_escape_hatch() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (version guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_installed_plugins "$sb/installed.json" "0.0.1-stale"
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_SKIP_VERSION_CHECK=1 \
            CLAUDE_INSTALLED_PLUGINS="$sb/installed.json" \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "escape hatch proceeds past the guard to missing-worktree exit 2"
    assert_contains "$RUN_OUT" "proceeding anyway" "warns but continues under the escape hatch"
}

# The registry's active record carries the in-band sentinel "version": "unknown"
# (Claude Code writes this for plugins it can't version-pin — most of a real
# installed_plugins.json). It must be treated as undeterminable, NOT as a real
# value that mismatches the running semver → the guard skips, launch reaches its
# normal missing-worktree exit 2. Guards against a false-positive refusal.
test_launch_version_unknown_sentinel_skips() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (version guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_installed_plugins "$sb/installed.json" "unknown"
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_INSTALLED_PLUGINS="$sb/installed.json" \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" launch 999 2>&1)" || RUN_RC=$?
    assert_exit 2 "$RUN_RC" "unknown-sentinel version skips the guard, reaches missing-worktree exit 2"
    assert_not_contains "$RUN_OUT" "version skew" "the 'unknown' sentinel is not treated as a real mismatch"
}

# With HOME unset and no CLAUDE_INSTALLED_PLUGINS override, the registry path
# default must degrade to an unreadable path (→ skip), NOT abort the whole script
# with `HOME: unbound variable` under `set -u`. `print` still exits 0.
test_launch_unset_home_does_not_crash() {
    local sb
    new_sandbox sb
    RUN_RC=0
    # Deliberately DO NOT pass HOME or CLAUDE_INSTALLED_PLUGINS.
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uHOME \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" "$LAUNCH" print 5 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "unset HOME does not crash the guard (print exits 0)"
    assert_contains "$RUN_OUT" "tmux new-session" "print still emits its line with HOME unset"
    assert_not_contains "$RUN_OUT" "unbound variable" "no nounset abort on the HOME default"
}

# No installed-plugins registry (the common host / bare-linux case) → the active
# version is undeterminable, so the guard SKIPS silently. `print` emits its line
# with no skew warning.
test_launch_version_undeterminable_skips() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_PLUGIN_PROBE="$sb/no-plugin-probe" \
            GOLEM_STATUS_DIR=.worktrees/.status \
            CLAUDE_INSTALLED_PLUGINS="$sb/no-such-registry.json" \
            "$REAL_BASH" "$LAUNCH" print 5 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "undeterminable version skips the guard, print exits 0"
    assert_contains "$RUN_OUT" "tmux new-session" "print still emits its line"
    assert_not_contains "$RUN_OUT" "version skew" "no skew warning when undeterminable"
}

# --- golem-launch.sh auth-token injection (#244) ----------------------------
# `launch` resolves ANTHROPIC_AUTH_TOKEN and passes it via `tmux -e`. To exercise
# the real dispatch (past the missing-worktree guard) without a real tmux server,
# each case prepends a `$sb/bin` stub `tmux` that logs its argv to
# $sb/tmux-args.log and exits 0, and creates the .worktrees/issue-N dir so the
# `[ -d ]` guard passes. Settings carry all rules so preflight is a silent no-op.
# ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL are explicitly --unset so the suite's
# own environment can never taint the resolution under test.

# A readable op-secrets cache with a token + base URL → both are injected into
# the tmux `-e` args, and the token is NEVER echoed to stdout/stderr.
test_launch_auth_cache_injects_token() {
    local sb log
    new_sandbox sb
    command printf 'export ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244\nexport ANTHROPIC_BASE_URL=https://bifrost.example\n' >"$sb/op-cache"
    run_launch_auth "$sb" OP_SECRETS_CACHE="$sb/op-cache"
    assert_exit 0 "$RUN_RC" "launch with a cache token dispatches (exit 0)"
    log="$(command cat "$sb/tmux-args.log" 2>/dev/null || true)"
    assert_contains "$log" "ANTHROPIC_AUTH_TOKEN=sk-secret-tok-244" "the resolved token is injected via tmux -e"
    assert_contains "$log" "ANTHROPIC_BASE_URL=https://bifrost.example" "the cache base URL rides along"
    assert_not_contains "$RUN_OUT" "sk-secret-tok-244" "the token is NEVER echoed to stdout/stderr"
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
    assert_not_contains "$log" "ANTHROPIC_AUTH_TOKEN" "no token is injected when none resolves"
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
    assert_not_contains "$log" "ANTHROPIC_AUTH_TOKEN" "a timed-out op read injects no token"
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
    assert_not_contains "$log" "ANTHROPIC_AUTH_TOKEN" "no empty token is injected"
}

# --- golem-launch.sh plugin-resolvability guard (#946) ----------------------
#
# The skew guard above catches a STALE plugin; this guard catches an ABSENT one.
# The marketplace registration has been observed to vanish mid-session, after
# which every NEW golem dies on `Unknown command: /workflow:next-issue` and then
# idles — which the watcher reads as a quiet lane, not a broken one.
#
# The probe binary is stubbed via GOLEM_PLUGIN_PROBE rather than by shimming
# `claude` onto PATH: the tests then never depend on whether the host running
# them has a real `claude`, and a stub cannot be shadowed by one.

# write_plugin_probe <path> <mode> — fabricate a stub standing in for
# `claude plugin details`. Modes mirror the states the guard must separate:
#   ok        exit 0, a non-zero skill count  → healthy
#   notfound  exit 1, the CLI's real message  → gone
#   zero      exit 0 but "Skills (0)"         → resolves, discovers nothing
#   hang      sleeps past any sane bound      → unresponsive
write_plugin_probe() {
    local path="$1" mode="$2"
    case "$mode" in
        ok)
            command cat >"$path" <<'EOF'
#!/usr/bin/env bash
echo "workflow 9.9.9"
echo "  Skills (10)  file-issue, golem, next-issue"
exit 0
EOF
            ;;
        notfound)
            command cat >"$path" <<'EOF'
#!/usr/bin/env bash
echo 'Plugin "workflow@librarian" not found.' >&2
exit 1
EOF
            ;;
        zero)
            command cat >"$path" <<'EOF'
#!/usr/bin/env bash
echo "workflow 9.9.9"
echo "  Skills (0)  "
exit 0
EOF
            ;;
        hang)
            command cat >"$path" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
            ;;
        reworded)
            # Exit 0, but the count line no longer says "Skills (N)" — what a CLI
            # rewording, an added ANSI sequence, or a localized string looks like.
            command cat >"$path" <<'EOF'
#!/usr/bin/env bash
echo "workflow 9.9.9"
echo "  Commands (10)  file-issue, golem, next-issue"
exit 0
EOF
            ;;
    esac
    command chmod +x "$path"
}

# _plugin_probe_run <sandbox> <probe-path> <subcommand> [extra-env...]
# Run golem-launch.sh with the stub wired in. Mirrors run_in's scrubbing but adds
# the probe env; a short timeout keeps the hang case from stalling the suite.
_plugin_probe_run() {
    local dir="$1" probe="$2" sub="$3"
    shift 3
    RUN_RC=0
    RUN_OUT="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            GOLEM_PLUGIN_PROBE="$probe" \
            GOLEM_PLUGIN_PROBE_TIMEOUT=3 \
            "$@" \
            "$REAL_BASH" "$LAUNCH" "$sub" 946 2>&1)" || RUN_RC=$?
}

# A resolvable plugin must not interfere: the run falls through to its normal
# missing-worktree exit 2, with no refusal or warning text. This is the control —
# without it, a guard that refused unconditionally would pass every test below.
test_launch_plugin_resolvable_passes() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" ok
    _plugin_probe_run "$sb" "$sb/probe" launch
    assert_exit 2 "$RUN_RC" "a resolvable plugin passes the guard, reaching missing-worktree exit 2"
    assert_not_contains "$RUN_OUT" "REFUSING to dispatch" "no refusal for a healthy plugin"
    assert_not_contains "$RUN_OUT" "not resolvable" "no warning for a healthy plugin"
}

# The headline case: the plugin is gone, so launch must refuse with exit 3 rather
# than dispatch a golem that dies at its first prompt.
test_launch_plugin_absent_refuses_exit_3() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" notfound
    _plugin_probe_run "$sb" "$sb/probe" launch
    assert_exit 3 "$RUN_RC" "an unresolvable plugin refuses dispatch with exit 3"
    assert_contains "$RUN_OUT" "REFUSING to dispatch" "the refusal is loud"
    assert_contains "$RUN_OUT" "Unknown command" "names the symptom the operator would otherwise see"
    assert_contains "$RUN_OUT" "claude plugin marketplace add" "names the actual fix, not just the problem"
}

# THE FALSE-PASS CASE. The probe exits 0 but reports zero components — a plugin
# that resolves yet discovers nothing, which is exactly what CLAUDE.md warns
# manifest validation cannot see. An exit-code-only check passes this and
# dispatches a golem with no /workflow:next-issue; asserting the refusal here is
# what makes the guard a capability probe rather than a liveness formality.
test_launch_plugin_zero_skills_refuses() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" zero
    _plugin_probe_run "$sb" "$sb/probe" launch
    assert_exit 3 "$RUN_RC" "exit 0 with zero skills still refuses (not an exit-code-only check)"
    assert_contains "$RUN_OUT" "reports 0 skills" "the message distinguishes zero-skills from wholly absent"
}

# An unresponsive CLI is not evidence of a healthy plugin, so a timeout is a
# REFUSAL, not a skip — and it must be bounded. The elapsed-time assertion is the
# real subject: an earlier draft captured the probe through a command
# substitution, where an orphaned grandchild holds the pipe open and the caller
# blocks for the child's FULL lifetime even though the bound fired. That guard
# returned the right code after 60s instead of 3s — correct exit, useless bound.
test_launch_plugin_probe_timeout_is_bounded_refusal() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb start elapsed
    new_sandbox sb
    write_plugin_probe "$sb/probe" hang
    start="$(command date +%s)"
    _plugin_probe_run "$sb" "$sb/probe" launch
    elapsed=$(($(command date +%s) - start))
    assert_exit 3 "$RUN_RC" "a timed-out probe refuses rather than passing"
    assert_true "[ $elapsed -lt 30 ]" "the probe is genuinely bounded (took ${elapsed}s against a 60s hang)"
}

# The escape hatch mirrors GOLEM_SKIP_VERSION_CHECK=1: warn, then proceed.
test_launch_plugin_check_escape_hatch() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" notfound
    _plugin_probe_run "$sb" "$sb/probe" launch GOLEM_SKIP_PLUGIN_CHECK=1
    assert_exit 2 "$RUN_RC" "the escape hatch downgrades the refusal, reaching missing-worktree exit 2"
    assert_contains "$RUN_OUT" "GOLEM_SKIP_PLUGIN_CHECK=1" "the downgrade is still announced"
    assert_not_contains "$RUN_OUT" "REFUSING to dispatch" "no refusal under the escape hatch"
}

# No probe binary on PATH → undeterminable → skip SILENTLY, matching the skew
# guard's contract. Refusing here would break a bare host that dispatches by
# other means; the launch line's own `claude` fails loudly on its own anyway.
test_launch_plugin_probe_absent_skips_silently() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    _plugin_probe_run "$sb" "$sb/no-such-probe-binary" launch
    assert_exit 2 "$RUN_RC" "an absent probe skips the guard, reaching missing-worktree exit 2"
    assert_not_contains "$RUN_OUT" "REFUSING to dispatch" "no refusal when the probe is undeterminable"
    assert_not_contains "$RUN_OUT" "not resolvable" "and no warning either — the skip is silent"
}

# `print` has no side effect worth blocking, so it warns and still emits the
# line. Asserting BOTH halves: a print that refused would break the documented
# "show me the launch line" path, and one that stayed quiet would hide the fault.
test_print_plugin_absent_warns_but_emits() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" notfound
    _plugin_probe_run "$sb" "$sb/probe" print
    assert_exit 0 "$RUN_RC" "print still exits 0 with an unresolvable plugin"
    assert_contains "$RUN_OUT" "WARNING" "print warns about the unresolvable plugin"
    assert_contains "$RUN_OUT" "tmux new-session" "print still emits the launch line"
}

# The refusal text is operator-facing: a human reads it and TYPES what it says.
# A bare `/next-issue` does not resolve as installed (#584/#230), so the message
# must carry the namespaced form only. Asserted against the source because the
# guard's own text is the subject, not any one runtime path.
test_plugin_guard_message_namespaces_commands() {
    assert_true "! command sed -n '/check_plugin_resolvable/,/^}/p' '$LAUNCH' | command grep -qE '(^|[^:])/next-issue'" \
        "the plugin-guard refusal carries no bare (un-namespaced) /next-issue"
    # NON-VACUITY: the namespaced form must actually be present, or a guard that
    # dropped the message entirely would satisfy the assertion above.
    assert_true "command grep -q '/workflow:next-issue' '$LAUNCH'" \
        "the namespaced /workflow:next-issue is actually present in the guard"
}

# The guard has THREE call sites (launch / print / preflight) and the tests above
# drive only two. `preflight` is the one an operator runs by hand, and both
# README.md and orchestrate/SKILL.md now document it as reporting plugin health —
# so an untested third arm is a documented feature with no coverage.
#
# Two properties, and the second is the subtle one: preflight must WARN, but its
# own exit code must stay governed by the settings-rules check. If the guard
# leaked its exit 3 here, `launch`'s `preflight || true` would swallow it while a
# hand-run preflight started failing for a reason its message never mentions.
test_preflight_plugin_absent_warns_without_changing_exit() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" notfound
    # Settings with all three rules present → preflight's own verdict is exit 0.
    command cat >"$sb/proj-settings.json" <<'EOF'
{ "permissions": { "allow": ["Bash(tmux new-session:*)", "Bash(tmux ls:*)", "Bash(tmux kill-session:*)"] } }
EOF
    command printf '{}\n' >"$sb/global-settings.json"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_PLUGIN_PROBE="$sb/probe" \
            GOLEM_PLUGIN_PROBE_TIMEOUT=3 \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" preflight 2>&1)" || RUN_RC=$?
    assert_contains "$RUN_OUT" "WARNING" "preflight surfaces the unresolvable plugin"
    assert_exit 0 "$RUN_RC" "the guard does not change preflight's own exit code"
    assert_not_contains "$RUN_OUT" "REFUSING to dispatch" "preflight reports, it does not refuse"
}

# GOLEM_MARKETPLACE is an operator-facing knob the refusal message itself tells
# people to set, so it must actually reach the probe. Asserted through a
# RECORDING stub rather than through the message alone: the message could name
# the override while the probe was still called with the default, which is the
# failure that would make the remediation advice useless.
test_plugin_probe_honors_marketplace_override() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/probe" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RECORD_ARGV"
echo 'Plugin not found.' >&2
exit 1
EOF
    command chmod +x "$sb/probe"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_PLUGIN_PROBE="$sb/probe" \
            GOLEM_PLUGIN_PROBE_TIMEOUT=3 \
            GOLEM_MARKETPLACE=other-mp \
            RECORD_ARGV="$sb/argv.log" \
            "$REAL_BASH" "$LAUNCH" print 946 2>&1)" || RUN_RC=$?
    local argv
    argv="$(command cat "$sb/argv.log" 2>/dev/null || true)"
    assert_contains "$argv" "@other-mp" "the probe is invoked against the overridden marketplace"
    assert_not_contains "$argv" "@librarian" "the default marketplace is not used once overridden"
    assert_contains "$RUN_OUT" "other-mp" "the operator-facing message names the marketplace actually probed"
}

# THE FAIL-OPEN DIRECTION. The count is scraped from the CLI's human-readable
# text because `plugin details` has no structured output mode (probed: no
# --json). So the scraper WILL eventually stop matching — a rewording, an ANSI
# sequence, a localized string — and the question is which way it fails then.
#
# Treating unparseable output as "plugin absent" would refuse EVERY dispatch on
# EVERY host the moment the CLI's phrasing changed: a total outage, in the exact
# opposite direction from the false pass this guard exists to catch. A scraper
# that cannot read its input has learned nothing, so it must warn and proceed.
#
# This test is the whole reason the guard distinguishes three probe outcomes
# rather than two; without it, "simplifying" the empty-count branches back into
# one would look like a cleanup and would silently arm the outage.
test_launch_unparseable_probe_output_warns_but_proceeds() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" reworded
    _plugin_probe_run "$sb" "$sb/probe" launch
    assert_exit 2 "$RUN_RC" "unrecognizable output proceeds (reaches missing-worktree exit 2), never refuses"
    assert_not_contains "$RUN_OUT" "REFUSING to dispatch" "a CLI rewording must not block dispatch"
    assert_contains "$RUN_OUT" "UNVERIFIED" "but it is announced, not silently treated as healthy"
}

# The companion assertion: a probe that exits 0 while reporting a real ZERO is a
# different fact from one whose output cannot be read, and must keep refusing.
# Pinned separately so a future change cannot collapse the two branches and call
# every zero "unparseable" — which would re-open the false pass from the other side.
test_zero_and_unparsed_are_distinct_outcomes() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/zero" zero
    write_plugin_probe "$sb/reworded" reworded
    _plugin_probe_run "$sb" "$sb/zero" launch
    assert_exit 3 "$RUN_RC" "an explicit zero count still refuses"
    _plugin_probe_run "$sb" "$sb/reworded" launch
    assert_exit 2 "$RUN_RC" "an unreadable count does not — the two outcomes stay distinct"
}

# The SAME fail-open question, one layer down. `plugin_skill_count` needs a
# scratch file to hold the probe's stdout (a command substitution cannot bound —
# see the timeout test above), and an unwritable TMPDIR makes that mktemp fail.
# An early `return 0` there would emit an empty count, which the caller reads as
# "plugin absent" — so a read-only /tmp would refuse every dispatch on the host
# for a reason having nothing to do with the plugin.
#
# Found while re-reading the fix, not by a reviewer: the same defect class as the
# unparsed branch, reached by a different route. Both must announce UNVERIFIED
# and proceed, and each must name its OWN cause — a temp-file failure reported as
# "the CLI format changed" would send an operator to update a working scraper.
test_launch_unwritable_tmpdir_warns_but_proceeds() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" ok
    _plugin_probe_run "$sb" "$sb/probe" launch TMPDIR="$sb/no-such-tmpdir"
    assert_exit 2 "$RUN_RC" "an unusable TMPDIR proceeds (missing-worktree exit 2), never refuses"
    assert_not_contains "$RUN_OUT" "REFUSING to dispatch" "a scratch-file failure must not block dispatch"
    assert_contains "$RUN_OUT" "UNVERIFIED" "it is announced rather than passing as healthy"
    assert_contains "$RUN_OUT" "TMPDIR" "and names its own cause, not a CLI-format change"
    assert_contains "$RUN_OUT" "FILE" "the file failure is reported as such, distinct from the directory one"
}

# The unverified outcomes across the OTHER two call sites. `launch` is covered
# above; this pins that `print` and `preflight` agree with it — all three must
# warn and let the operator proceed, since none of them learned anything about
# the plugin. A divergence here would mean the arm an operator runs by hand
# reports a different health verdict than the arm that dispatches.
#
# Scope, stated precisely so the name does not over-claim: `unparsed` is driven
# through print AND preflight; `noscratch` through print (its launch coverage is
# test_launch_unwritable_tmpdir_warns_but_proceeds). Both branches sit before the
# mode dispatch, so this asserts the placement that makes them mode-independent —
# it is not an exhaustive per-outcome × per-mode matrix.
test_unverified_outcomes_agree_across_call_sites() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    write_plugin_probe "$sb/probe" reworded
    command printf '{}\n' >"$sb/proj-settings.json"
    command printf '{}\n' >"$sb/global-settings.json"

    _plugin_probe_run "$sb" "$sb/probe" print
    assert_exit 0 "$RUN_RC" "print exits 0 on an unreadable count"
    assert_contains "$RUN_OUT" "UNVERIFIED" "print announces the unverified state"
    assert_contains "$RUN_OUT" "tmux new-session" "print still emits the launch line"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_PLUGIN_PROBE="$sb/probe" \
            GOLEM_PLUGIN_PROBE_TIMEOUT=3 \
            CLAUDE_PROJECT_SETTINGS=proj-settings.json \
            CLAUDE_GLOBAL_SETTINGS="$sb/global-settings.json" \
            "$REAL_BASH" "$LAUNCH" preflight 2>&1)" || RUN_RC=$?
    assert_contains "$RUN_OUT" "UNVERIFIED" "preflight announces the unverified state too"
    assert_not_contains "$RUN_OUT" "REFUSING to dispatch" "and never refuses on it"

    # The OTHER unverified outcome, through print. `noscratch` and `unparsed`
    # are separate branches with separate messages, so covering one says nothing
    # about the other — and an unwritable TMPDIR reaches noscratch through the
    # plain-file mktemp, which a test can actually drive.
    write_plugin_probe "$sb/ok" ok
    _plugin_probe_run "$sb" "$sb/ok" print TMPDIR="$sb/no-such-tmpdir"
    assert_exit 0 "$RUN_RC" "print exits 0 when no scratch file can be made"
    assert_contains "$RUN_OUT" "UNVERIFIED" "print announces the scratch-file failure"
    assert_contains "$RUN_OUT" "TMPDIR" "naming its own cause, not a CLI-format change"
    assert_contains "$RUN_OUT" "tmux new-session" "and still emits the launch line"
}

# The THIRD fail-closed instance: bounded_run creates its own marker DIRECTORY
# and returns 2 when that fails (bounded-run.sh:63) — a return plugin_skill_count
# cannot distinguish from a probe genuinely exiting 2, which would drop it back
# into the "plugin absent" bucket and refuse dispatch.
#
# An earlier draft of this change called the branch untestable, on the strength
# of a PATH stub that was never invoked. That diagnosis was wrong, and the reason
# is worth keeping: BASH_ENV=/etc/bash_env re-sources a profile that RESTORES
# PATH, so the stub was discarded before the script ran. `-uBASH_ENV` is
# the fix, and this harness already carries that exact idiom for the same reason
# (see run_launch_auth in tests/lib/golem-sandbox.sh).
#
# A plain unwritable TMPDIR cannot reach this branch — it fails the plain-file
# `mktemp` first and returns at the earlier guard. The stub below is what
# isolates the arm: it fails ONLY on `-d` and delegates everything else, which is
# the real asymmetry (a directory-entry quota, some FUSE/overlay mounts, or a
# write-but-not-mkdir ACL) reproduced faithfully.
test_launch_scratch_dir_failure_is_unverified_not_absent() {
    # The guard derives the plugin NAME from its manifest via jq; without jq
    # running_plugin_name returns empty and check_plugin_resolvable skips
    # entirely, so every assertion below would be asserting an absent warning.
    # Same gate, same reason, as the sibling version-skew tests above.
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (plugin guard no-ops without jq)"
        return 0
    fi
    local sb stub
    new_sandbox sb
    write_plugin_probe "$sb/probe" ok
    stub="$sb/mktemp-stub"
    command mkdir -p "$stub"
    # Delegates via `command -p`, which searches the SYSTEM default PATH and so
    # cannot re-find this stub (a plain `mktemp` here would recurse forever) —
    # and, unlike a hardcoded /usr/bin/mktemp, resolves wherever the real binary
    # lives on the host (#443: no hardcoded core-utility paths). Not `exec`ed:
    # `command` is a shell builtin, so `exec command …` is a 127.
    command cat >"$stub/mktemp" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-d" ] && exit 1; done
command -p mktemp "$@"
EOF
    command chmod +x "$stub/mktemp"

    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            PATH="$stub:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_PLUGIN_PROBE="$sb/probe" \
            GOLEM_PLUGIN_PROBE_TIMEOUT=3 \
            "$REAL_BASH" "$LAUNCH" launch 946 2>&1)" || RUN_RC=$?

    assert_not_contains "$RUN_OUT" "REFUSING to dispatch" \
        "a scratch-DIRECTORY failure is unverified, never a plugin absence"
    assert_contains "$RUN_OUT" "UNVERIFIED" "and it is announced, not passed off as healthy"
    # The DIRECTORY wording specifically: reporting this as a temp-FILE failure
    # would send the operator to check the one thing already known to work.
    assert_contains "$RUN_OUT" "DIRECTORY" "the message names the directory failure, not the file one"
    assert_exit 2 "$RUN_RC" "dispatch proceeds to its normal missing-worktree exit"

    # Same outcome through print — the branch sits before the mode dispatch, and
    # this is the newest of the three fail-closed guards, so it is the one most
    # worth pinning across call sites rather than assuming.
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/-u}" -uBASH_ENV \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            PATH="$stub:$PATH" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_PLUGIN_PROBE="$sb/probe" \
            GOLEM_PLUGIN_PROBE_TIMEOUT=3 \
            "$REAL_BASH" "$LAUNCH" print 946 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "print exits 0 on a scratch-directory failure"
    assert_contains "$RUN_OUT" "UNVERIFIED" "print reaches the same unverified verdict as launch"
    assert_contains "$RUN_OUT" "tmux new-session" "and still emits the launch line"
}
