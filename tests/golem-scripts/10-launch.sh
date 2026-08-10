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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=HOME \
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
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" GOLEM_WORKTREE_DIR=.worktrees \
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
# set with no cache/env token, so resolution reaches the bounded op arm. Skipped
# where neither timeout nor gtimeout exists (the arm no-ops there by design).
test_launch_auth_op_hang_is_bounded() {
    if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
        skip_test "neither timeout nor gtimeout available (bounded-op arm is a no-op)"
        return 0
    fi
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
